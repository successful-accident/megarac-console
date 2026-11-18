// SPDX-FileCopyrightText: 2026 Jeff Morrison
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Replacements for the three native media libraries of the AMI JViewer. The BMC
// serves them for macOS only as Intel code (Mac64.jar), and for some systems not
// at all, so this file stands in for all three wherever a C compiler runs:
// Apple silicon and Intel Macs, Linux on any CPU, FreeBSD.
//
// Only ISO images are real: one mounts as the server's virtual CD. Physical CD
// drives, and floppy and hard-disk redirection, report "no drives" and refuse to
// open. The keyboard calls the viewer needs to start video return what the Intel
// library returned on a Mac.
//
// The CD image logic is a line-for-line port of the Intel library's
// imagereader.c, quirks included, because the BMC was only ever tested against
// that. test/test-media.sh checks that every build gives the same replies,
// byte for byte; keep it passing when changing anything below.
#include <fcntl.h>
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// An IUSB SCSI packet: 32-byte header, then lengths and tags, the command at
// 41, a 4-byte status at 53, the data length at 57 and the data from 61.
enum { CDB = 41, STATUS = 53, DATALEN = 57, DATA = 61, SECTOR = 0x800 };

typedef struct {
    char path[0x104];
    int fd;
    uint32_t sectors, block; // as of the last capacity check
    uint8_t reopen;  // set by open, and whenever the image cannot be opened:
                     // the next command does nothing but clear it
    uint8_t opened;
    uint8_t changed; // report "medium may have changed" once after open
} cd_t;

static uint32_t be16(const uint8_t *p) { return p[0] << 8 | p[1]; }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static void put_be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void put_le32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static int open_image(cd_t *c) {
    c->fd = open(c->path, O_RDONLY);
    return c->fd == -1 ? -5 : 0;
}

static void close_image(cd_t *c) {
    if (c->fd != -1) close(c->fd);
}

// Also the "test unit ready" check: the image must still hold sector 16.
static int read_capacity(cd_t *c) {
    uint8_t sector[SECTOR];
    struct stat st = {0};
    if (lseek(c->fd, 16 * SECTOR, SEEK_SET) == -1) return -4;
    if (read(c->fd, sector, SECTOR) != SECTOR) return -7;
    if (lseek(c->fd, 0, SEEK_END) == -1) return -4;
    stat(c->path, &st);
    c->block = SECTOR;
    c->sectors = (uint32_t)(st.st_size / SECTOR);
    return 0;
}

static int validate(cd_t *c) {
    char sector[SECTOR + 1] = {0};
    if (lseek(c->fd, 16 * SECTOR, SEEK_SET) == -1) return -4;
    if (read(c->fd, sector, SECTOR) != SECTOR) return -7;
    return strstr(sector + 1, "CD001") ? 0 : -2;
}

static int open_cd(cd_t *c, const char *path) {
    int ret;
    if (c->opened == 1) return -12;
    c->opened = 0;
    if (strlen(path) > 0x100) return -10;
    strcpy(c->path, path);
    if ((ret = open_image(c))) return ret;
    if ((ret = validate(c)) == 0) ret = read_capacity(c);
    close(c->fd);
    if (ret == 0) c->reopen = c->opened = c->changed = 1;
    return ret;
}

static int read_sectors(cd_t *c, uint32_t lba, uint32_t count, uint32_t *len, uint8_t *out, size_t room) {
    uint32_t bytes = c->block * count;
    if (c->sectors < count) return -1; // sic: the count, not the end of the read
    if (bytes > room) return -1;       // the Intel library overruns its buffer here
    if (lseek(c->fd, (off_t)lba * c->block, SEEK_SET) == -1) return -1;
    ssize_t n = read(c->fd, out, bytes);
    if (n != (ssize_t)bytes) return n == 0 ? -1 : -4;
    *len = bytes;
    return 0;
}

static int read_toc(cd_t *c, const uint8_t *cdb, uint32_t *len, uint8_t *toc) {
    uint32_t n = 4, track = cdb[6], room = be16(cdb + 7), end = c->sectors + 150;
    if (track > 1 && track != 0xAA) return 0;
    toc[2] = toc[3] = 1; // first and last track
    if (track <= 1) {
        const uint8_t one[8] = {0, 0x14, 1, 0, 0, 0, cdb[1] & 2 ? 2 : 0, 0};
        memcpy(toc + n, one, 8);
        n += 8;
    }
    // Lead-out. Its address is always minute/second/frame, whatever was asked for.
    const uint8_t out[8] = {0, 0x16, 0xAA, 0, 0, end / 4500, end / 75 % 60, end % 75};
    memcpy(toc + n, out, 8);
    n += 8;
    if (n > room) n = room;
    toc[0] = (n - 2) >> 8;
    toc[1] = n - 2;
    *len = n;
    return 0;
}

static void set_status(int ret, uint8_t *resp) {
    static const uint8_t table[9][4] = {
        {1, 5, 0x53, 2}, // -8 media removal prevented
        {1, 3, 0x30, 2}, // -7 incompatible format
        {1, 5, 0x26, 0}, // -6 invalid field
        {1, 2, 0x3a, 0}, // -5 medium not present
        {1, 3, 0x11, 0}, // -4 unrecovered read error
        {1, 6, 0x28, 0}, // -3 medium may have changed
        {0, 3, 0x30, 1}, // -2 unknown format
        {1, 5, 0x21, 0}, // -1 block address out of range
        {0, 0, 0, 0},    //  0 good
    };
    static const uint8_t unsupported[4] = {1, 5, 0x20, 0};
    memcpy(resp + STATUS, ret >= -8 && ret <= 0 ? table[ret + 8] : unsupported, 4);
}

// Returns the number of data bytes placed after the 61-byte packet.
static uint32_t execute(cd_t *c, const uint8_t *req, uint8_t *resp, size_t room) {
    const uint8_t *cdb = req + CDB;
    uint8_t *data = resp + DATA;
    uint32_t len = 0;
    memcpy(resp, req, 62);
    int ret = c->opened == 1 ? open_image(c) : -5;
    if (ret != 0) {
        c->reopen = 1;
    } else if (c->reopen) {
        c->reopen = 0;
        close_image(c);
    } else {
        switch (cdb[0]) {
        case 0x00: // test unit ready
            if (c->changed) { c->changed = 0; ret = -3; }
            else ret = read_capacity(c);
            break;
        case 0x25: // read capacity
            if (c->changed) { c->changed = 0; ret = -3; break; }
            ret = read_capacity(c);
            put_be32(data, c->sectors - 1);
            put_be32(data + 4, c->block);
            len = 8;
            break;
        case 0x28: case 0xA8: // read (10) and (12); both take the 16-bit count
            ret = read_sectors(c, be32(cdb + 2), be16(cdb + 7), &len, data, room - DATA);
            break;
        case 0x43:
            ret = read_toc(c, cdb, &len, data);
            break;
        case 0x1B: // start/stop unit
            break;
        default:
            ret = -9;
        }
        close_image(c);
    }
    set_status(ret, resp);
    put_le32(resp + DATALEN, len);
    return len;
}

// ---- JNI. Each Java object keeps its reader in a long field, -1 for none.

static jfieldID field(JNIEnv *e, jobject o) {
    return (*e)->GetFieldID(e, (*e)->GetObjectClass(e, o), "nativeReaderPointer", "J");
}
static void *reader(JNIEnv *e, jobject o) {
    jlong p = (*e)->GetLongField(e, o, field(e, o));
    return p > 0 ? (void *)(intptr_t)p : NULL;
}
static void set_reader(JNIEnv *e, jobject o, void *p) {
    free(reader(e, o));
    (*e)->SetLongField(e, o, field(e, o), p ? (jlong)(intptr_t)p : -1);
}
static jstring version(JNIEnv *e, jobject o, const char *v) {
    return reader(e, o) ? (*e)->NewStringUTF(e, v) : NULL;
}
#define NATIVE(type, cls, name, ...) \
    JNIEXPORT type JNICALL Java_com_ami_iusb_##cls##_##name(JNIEnv *e, jobject o, ##__VA_ARGS__)

NATIVE(void, CDROMRedir, newCDROMReader, jboolean physical) {
    cd_t *c = calloc(1, sizeof *c);
    c->fd = -1;
    c->opened = physical ? 2 : 0; // 2: never opens, so every command says "no medium"
    set_reader(e, o, c);
}
NATIVE(void, CDROMRedir, deleteCDROMReader) { set_reader(e, o, NULL); }
NATIVE(jboolean, CDROMRedir, openCDROM, jbyteArray path) {
    cd_t *c = reader(e, o);
    jsize n = (*e)->GetArrayLength(e, path);
    char *p = calloc(1, n + 1);
    (*e)->GetByteArrayRegion(e, path, 0, n, (jbyte *)p);
    jboolean ok = c && c->opened != 2 && open_cd(c, p) == 0;
    free(p);
    return ok;
}
NATIVE(void, CDROMRedir, closeCDROM) {
    cd_t *c = reader(e, o);
    if (c && c->opened == 1) c->opened = 0;
}
NATIVE(jint, CDROMRedir, executeCDROMSCSICmd, jobject request, jobject response) {
    cd_t *c = reader(e, o);
    uint8_t *req = (*e)->GetDirectBufferAddress(e, request), *resp = (*e)->GetDirectBufferAddress(e, response);
    if (!c || !req || !resp) return -1;
    if ((*e)->GetDirectBufferCapacity(e, request) < 62 || (*e)->GetDirectBufferCapacity(e, response) < 128) return -1;
    return DATA + execute(c, req, resp, (*e)->GetDirectBufferCapacity(e, response));
}
NATIVE(jobjectArray, CDROMRedir, listCDROMDrives) { return NULL; }
NATIVE(jstring, CDROMRedir, getVersion) { return version(e, o, "1.8"); }

NATIVE(void, FloppyRedir, newFloppyReader, jboolean physical) { set_reader(e, o, malloc(1)); }
NATIVE(void, FloppyRedir, deleteFloppyReader) { set_reader(e, o, NULL); }
NATIVE(jboolean, FloppyRedir, openFloppy, jbyteArray path) { return JNI_FALSE; }
NATIVE(void, FloppyRedir, closeFloppy) {}
NATIVE(jint, FloppyRedir, executeFloppySCSICmd, jobject request, jobject response) { return -1; }
NATIVE(jobjectArray, FloppyRedir, listFloppyDrives) { return NULL; }
NATIVE(jstring, FloppyRedir, getVersion) { return version(e, o, "1.9"); }
// The viewer reads these two once video starts; without them it never does.
NATIVE(jstring, FloppyRedir, GetKeyboardName) { return (*e)->NewStringUTF(e, "EN"); }
NATIVE(jbyte, FloppyRedir, GetLEDStatus) { return 0; }

NATIVE(void, HarddiskRedir, newHarddiskReader, jboolean physical) { set_reader(e, o, malloc(1)); }
NATIVE(void, HarddiskRedir, deleteHarddiskReader) { set_reader(e, o, NULL); }
NATIVE(jint, HarddiskRedir, openHarddisk, jbyteArray path, jboolean physical) { return -5; }
NATIVE(void, HarddiskRedir, closeHarddisk) {}
NATIVE(jint, HarddiskRedir, executeHarddiskSCSICmd, jobject request, jobject response) { return -1; }
NATIVE(jobjectArray, HarddiskRedir, listHardDrives) { return NULL; }
NATIVE(jobjectArray, HarddiskRedir, listHardDrivesFixed) { return NULL; }
NATIVE(jstring, HarddiskRedir, getVersion) { return version(e, o, "1.9"); }
