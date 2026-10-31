/*
    bfinject - Inject shared libraries into running App Store apps on iOS 11.x < 11.2
    https://github.com/BishopFox/bfinject
    
    Carl Livitt @ Bishop Fox

	Based on code originally by 10n1c: https://github.com/stefanesser/dumpdecrypted/blob/master/dumpdecrypted.c
	Now with the following enhancements:
	- Dump ALL encrypted images in the target application: the app itself, its frameworks, etc.
	- Create a valid .ipa containing the decrypted binaries. Save it in ~/Documents/decrypted-app.ipa
	- The .ipa can be modified and re-signed with a developer cert for redeployment to non-jailbroken devices
	- Auto detection of all the necessary sandbox paths
	- Converted into an Objective-C class for ease of use.
*/
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <mach/mach.h>
#include <err.h>
#include <mach-o/ldsyms.h>
#include <libkern/OSCacheControl.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <errno.h>
#import "SSZipArchive/SSZipArchive.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <mach/vm_map.h>
#include <mach-o/dyld_images.h>
#include <mach/task_info.h>
#include <sys/mman.h>
#include <mach/machine.h>

#include "TDDumpDecrypted.h"
#import "TDUtils.h"

kern_return_t
mach_vm_read_overwrite(vm_map_t, mach_vm_address_t, mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
// kern_return_t mach_vm_read(vm_map_t target_task, mach_vm_address_t address, mach_vm_size_t size, vm_offset_t *data, mach_msg_type_number_t *dataCnt);
kern_return_t 
mach_vm_region(vm_map_read_t target_task, mach_vm_address_t *address, mach_vm_size_t *size, vm_region_flavor_t flavor, vm_region_info_t info, mach_msg_type_number_t *infoCnt, mach_port_t *object_name);


//#define DEBUG(...) NSLog(__VA_ARGS__);
// #define DEBUG(...) {}

#define swap32(value) (((value & 0xFF000000) >> 24) | ((value & 0x00FF0000) >> 8) | ((value & 0x0000FF00) << 8) | ((value & 0x000000FF) << 24) )

// V098: all remote reads use caller-owned buffers. Do not use vm_read:
// its returned allocation must be vm_deallocate'd, unlike malloc buffers.
// The upstream PATH_MAX-sized vm_read of a remote dyld imageFilePath can
// cross an unreadable mapping even when the NUL-terminated path is valid.
// Read page-bounded chunks, stop at NUL, and keep all bytes in caller-owned
// storage. A missing terminator or failed memory read is NOT a valid path.
static BOOL v097ReadRemotePath(vm_map_t task, mach_vm_address_t address,
                               char *output, size_t capacity) {
    if (!task || !address || !output || capacity < 2 || capacity > PATH_MAX) return NO;
    size_t used = 0;
    output[0] = '\0';
    while (used < capacity - 1) {
        const mach_vm_address_t cursor = address + (mach_vm_address_t)used;
        if (cursor < address) return NO;
        const size_t untilPageEnd = 4096 - (size_t)(cursor & 4095);
        size_t amount = capacity - 1 - used;
        if (amount > 128) amount = 128;
        if (amount > untilPageEnd) amount = untilPageEnd;
        mach_vm_size_t actual = 0;
        kern_return_t kr = mach_vm_read_overwrite(task, cursor, amount,
                         (mach_vm_address_t)(output + used), &actual);
        if (kr != KERN_SUCCESS || actual != amount) return NO;
        char *end = memchr(output + used, 0, amount);
        if (end) return YES;
        used += amount;
    }
    output[capacity - 1] = '\0';
    return NO;
}

static kern_return_t
readmem(mach_vm_offset_t *buffer, mach_vm_address_t address, mach_vm_size_t size, vm_map_t targetTask, vm_region_basic_info_data_64_t *info)
{
  // Region metadata is not used by callers. The former mach_vm_region
  // returned a send right through object_name on every 64-KiB chunk without
  // deallocating it, potentially thousands of leaked ports for ChatGPT.framework.
  // A bounded read with exact byte-count validation is sufficient here.
  (void)info;
  if (size == 0 || !targetTask || !buffer) return KERN_FAILURE;
  mach_vm_size_t nread = 0;
  kern_return_t kr = mach_vm_read_overwrite(targetTask, address, size,
                                             (mach_vm_address_t)buffer, &nread);
  if (kr)
  {
    fprintf(stderr, "[ERROR] vm_read failed! %d\n", kr);
    return KERN_FAILURE;
  }
  else if (nread != size)
  {
    fprintf(stderr, "[ERROR] vm_read failed! requested size: 0x%llx read: 0x%llx\n", size, nread);
    return KERN_FAILURE;
  }
  return KERN_SUCCESS;
}

int64_t
get_image_size(mach_vm_address_t address, vm_map_t targetTask, uint64_t *vmaddr_slide)
{
  vm_region_basic_info_data_64_t region_info = {0};
  // allocate a buffer to read the header info
  // NOTE: this is not exactly correct since the 64bit version has an extra 4 bytes
  // but this will work for this purpose so no need for more complexity!
  struct mach_header header = {0};
  if (readmem((mach_vm_offset_t*)&header, address, sizeof(struct mach_header), targetTask, &region_info))
  {
    printf("Can't read header!\n");
    return -1;
  }
  
  if (header.magic != MH_MAGIC && header.magic != MH_MAGIC_64)
  {
		printf("[ERROR] Target is not a mach-o binary!\n");
    return -1;
  }
  
  int64_t imagefilesize = -1;
  /* read the load commands */
  uint8_t *loadcmds = (uint8_t*)malloc(header.sizeofcmds);
  uint16_t mach_header_size = sizeof(struct mach_header);
  if (header.magic == MH_MAGIC_64)
  {
    mach_header_size = sizeof(struct mach_header_64);
  }
  if (readmem((mach_vm_offset_t*)loadcmds, address+mach_header_size, header.sizeofcmds, targetTask, &region_info))
  {
    printf("Can't read load commands\n");
    free(loadcmds);
    return -1;
  }
  
  /* process and retrieve address and size of linkedit */
  uint8_t *loadCmdAddress = 0;
  loadCmdAddress = (uint8_t*)loadcmds;
  struct load_command *loadCommand    = NULL;
  struct segment_command *segCmd      = NULL;
  struct segment_command_64 *segCmd64 = NULL;
  for (uint32_t i = 0; i < header.ncmds; i++)
  {
    loadCommand = (struct load_command*)loadCmdAddress;
    if (loadCommand->cmd == LC_SEGMENT)
    {
      segCmd = (struct segment_command*)loadCmdAddress;
      if (strncmp(segCmd->segname, "__PAGEZERO", 16) != 0)
      {
        if (strncmp(segCmd->segname, "__TEXT", 16) == 0)
        {
          *vmaddr_slide = address - segCmd->vmaddr;
        }
        imagefilesize += segCmd->filesize;
      }
    }
    else if (loadCommand->cmd == LC_SEGMENT_64)
    {
      segCmd64 = (struct segment_command_64*)loadCmdAddress;
      if (strncmp(segCmd64->segname, "__PAGEZERO", 16) != 0)
      {
        if (strncmp(segCmd64->segname, "__TEXT", 16) == 0)
        {
          *vmaddr_slide = address - segCmd64->vmaddr;
        }
        imagefilesize += segCmd64->filesize;
      }
    }
    // advance to next command
    loadCmdAddress += loadCommand->cmdsize;
  }
  free(loadcmds);
  return imagefilesize;
}

// Bound the parser to a 1 MiB load-command table, instead of allocating
// the entire on-disk framework. The caller provides the verified FAT slice.
static uint32_t find_off_cryptid(const char *filePath, uint32_t sliceOffset) {
    FILE *file = fopen(filePath, "rb");
    if (!file) return 0;
    uint32_t result = 0;
    uint8_t *commands = NULL;
    struct mach_header_64 mh = {0};
    do {
        if (fseeko(file, (off_t)sliceOffset, SEEK_SET) != 0 ||
            fread(&mh, 1, sizeof(mh), file) != sizeof(mh) ||
            mh.magic != MH_MAGIC_64 || mh.ncmds == 0 ||
            mh.ncmds > 4096 ||
            mh.sizeofcmds < mh.ncmds * sizeof(struct load_command) ||
            mh.sizeofcmds > 1024 * 1024) break;
        commands = malloc(mh.sizeofcmds);
        if (!commands || fread(commands, 1, mh.sizeofcmds, file) != mh.sizeofcmds) break;
        size_t cursor = 0;
        for (uint32_t i = 0; i < mh.ncmds; ++i) {
            if (cursor > mh.sizeofcmds ||
                mh.sizeofcmds - cursor < sizeof(struct load_command)) break;
            struct load_command *lc = (struct load_command *)(commands + cursor);
            if (lc->cmdsize < sizeof(struct load_command) ||
                lc->cmdsize > mh.sizeofcmds - cursor) break;
            if ((lc->cmd == LC_ENCRYPTION_INFO_64 &&
                 lc->cmdsize >= sizeof(struct encryption_info_command_64)) ||
                (lc->cmd == LC_ENCRYPTION_INFO &&
                 lc->cmdsize >= sizeof(struct encryption_info_command))) {
                struct encryption_info_command *enc = (struct encryption_info_command *)lc;
                if (enc->cryptid == 0 || enc->cryptsize == 0) break;
                uint64_t at = (uint64_t)sliceOffset + sizeof(mh) +
                    cursor + offsetof(struct encryption_info_command, cryptid);
                if (at <= UINT32_MAX) result = (uint32_t)at;
                break;
            }
            cursor += lc->cmdsize;
        }
    } while (0);
    free(commands);
    fclose(file);
    return result;
}

@implementation DumpDecrypted

-(id) initWithPathToBinary:(NSString *)pathToBinary appName:(NSString *)appName appVersion:(NSString *)appVersion {
	if(!self) {
		self = [super init];
	}

	self.appName = appName;
	self.appVersion = appVersion;

	[self setAppPath:[pathToBinary stringByDeletingLastPathComponent]];
	// [self setDocPath:[NSString stringWithFormat:@"%@/Documents", NSHomeDirectory()]];
	[self setDocPath:docPath()];

	char *lastPartOfAppPath = strdup([[self appPath] UTF8String]);
	lastPartOfAppPath = strrchr(lastPartOfAppPath, '/') + 1;
	NSLog(@"[trolldecrypt] init: appDirName: %s", lastPartOfAppPath);
	self->appDirName = strdup(lastPartOfAppPath);

	return self;
}


-(void) makeDirectories:(const char *)encryptedImageFilenameStr {
	char *appPath = (char *)[[self appPath] UTF8String];
	char *docPath = (char *)[[self docPath] UTF8String];
	char *savePtr;
	char *encryptedImagePathStr = savePtr = strdup(encryptedImageFilenameStr);
	self->filename = strdup(strrchr(encryptedImagePathStr, '/') + 1);

	// Normalize the filenames
	if(strstr(encryptedImagePathStr, "/private") == encryptedImagePathStr)
		encryptedImagePathStr += 8;
	if(strstr(appPath, "/private") == appPath)
		appPath += 8;
	
	// Find start of image path, relative to the base of the app sandbox (ie. /var/mobile/.../FooBar.app/THIS_PART_HERE)
	encryptedImagePathStr += strlen(appPath) + 1; // skip over the app path
	char *p = strrchr(encryptedImagePathStr, '/');
	if(p)
		*p = '\0';

	NSLog(@"[trolldecrypt] encryptedImagePathStr: %s", encryptedImagePathStr);
	
	NSFileManager *fm = [[NSFileManager alloc] init];
	NSError *err;
	char *lastPartOfAppPath = strdup(appPath); // Must free()
	lastPartOfAppPath = strrchr(lastPartOfAppPath, '/');
	lastPartOfAppPath++;
	NSString *path = [NSString stringWithFormat:@"%s/ipa/Payload/%s", docPath, lastPartOfAppPath];
	self->appDirPath = strdup([path UTF8String]);
	if(p)
		path = [NSString stringWithFormat:@"%@/%s", path, encryptedImagePathStr];

	NSLog(@"[trolldecrypt] make_directories making dir: %@", path);
	if(! [fm createDirectoryAtPath:path withIntermediateDirectories:true attributes:nil error:&err]) {
		NSLog(@"[trolldecrypt] WARNING: make_directories failed to make directory %@. Error: %@", path, err);
	}

	free(savePtr);

	snprintf(self->decryptedAppPathStr, PATH_MAX, "%s/%s", [path UTF8String], self->filename);

	return;
}

 
// Bound each protected-image copy to 64 KiB rather than allocating the
// entire encrypted framework in the app's address space.
static BOOL v055ReadExact(int fd, void *buffer, size_t count) {
    size_t done = 0;
    while (done < count) {
        ssize_t n = read(fd, (uint8_t *)buffer + done, count - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        done += (size_t)n;
    }
    return YES;
}
static BOOL v055WriteExact(int fd, const void *buffer, size_t count) {
    size_t done = 0;
    while (done < count) {
        ssize_t n = write(fd, (const uint8_t *)buffer + done, count - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        done += (size_t)n;
    }
    return YES;
}
static BOOL v055CopyExactly(int srcFd, int dstFd, uint64_t count) {
    uint8_t buf[65536];
    while (count) {
        size_t n = count > sizeof(buf) ? sizeof(buf) : (size_t)count;
        if (!v055ReadExact(srcFd, buf, n) || !v055WriteExact(dstFd, buf, n)) return NO;
        count -= n;
    }
    return YES;
}

-(BOOL) dumpDecryptedImage:(vm_address_t)imageAddress fileName:(const char *)encryptedImageFilenameStr image:(int)imageNum task:(vm_map_t)targetTask{
	// struct load_command *lc;
	struct encryption_info_command *eic;
	struct fat_header *fh;
	struct fat_arch *arch;
	// struct mach_header *mh;
	char buffer[1024];
	unsigned int fileoffs = 0, off_cryptid = 0;
	int i, fd, outfd, n;

    struct mach_header header = {0};
    vm_region_basic_info_data_64_t region_info = {0};
    if (readmem((mach_vm_offset_t*)&header, imageAddress, sizeof(struct mach_header), targetTask, &region_info))
    {
        NSLog(@"[trolldecrypt] Can't read header!");
        exit(1);
    }
    //XXX: change all image_mh -> header NOW
    
    struct load_command *lc = (struct load_command*)malloc(header.sizeofcmds);
	
	/* detect if this is a arm64 binary */
	if (header.magic == MH_MAGIC_64) {
		// lc = (struct load_command *)((unsigned char *)header + sizeof(struct mach_header_64));
        if (readmem((mach_vm_offset_t*)lc, imageAddress+sizeof(struct mach_header_64), header.sizeofcmds, targetTask, &region_info) != KERN_SUCCESS) {
            NSLog(@"[trolldecrypt-v045] load-command memory read failed (64-bit); refusing invalid output");
            free(lc);
            return false;
        }
		NSLog(@"[trolldecrypt] detected 64bit ARM binary in memory.\n");
	} else if(header.magic == MH_MAGIC) { /* we might want to check for other errors here, too */
		// lc = (struct load_command *)((unsigned char *)header + sizeof(struct mach_header));
        if (readmem((mach_vm_offset_t*)lc, imageAddress+sizeof(struct mach_header), header.sizeofcmds, targetTask, &region_info) != KERN_SUCCESS) {
            NSLog(@"[trolldecrypt-v045] load-command memory read failed (32-bit); refusing invalid output");
            free(lc);
            return false;
        }
		NSLog(@"[trolldecrypt] detected 32bit ARM binary in memory.\n");
	} else {
		NSLog(@"[trolldecrypt] No valid header found!!");
		return false;
	}


    // sleep(1);exit(1);
    const struct mach_header *image_mh = &header;
	
	/* searching all load commands for an LC_ENCRYPTION_INFO load command */
	for (i=0; i<image_mh->ncmds; i++) {
		if (lc->cmd == LC_ENCRYPTION_INFO || lc->cmd == LC_ENCRYPTION_INFO_64) {
			eic = (struct encryption_info_command *)lc;
            // struct encryption_info_command *eic = (uint8_t*)malloc(sizeof(struct encryption_info_command););
            // readmem((mach_vm_offset_t*)eic, imageAddress+sizeof(struct mach_header_64), header.sizeofcmds, targetTask, &region_info);
			
			const char *appFilename = strrchr(encryptedImageFilenameStr, '/');
			if(appFilename == NULL) {
				NSLog(@"[trolldecrypt] There are no / in the filename. This is an error.\n");
				return false;
			}
			appFilename++;

			/* If this load command is present, but data is not crypted then exit */
			if (eic->cryptid == 0) {
				NSLog(@"[trolldecrypt] CryptID = 0!! ");
				return false;
			}

			// Create a dir structure in ~ just like in /path/to/FooApp.app/Whatever
			[self makeDirectories:encryptedImageFilenameStr];

            // V098: skip unused ASLR/file-size diagnostics. The old
            // get_image_size parser trusted unchecked remote load commands,
            // and its return value was not used to validate the extraction.
            // Actual on-disk cryptid offset is resolved after FAT slice selection.

			NSLog(@"[trolldecrypt] offset to cryptid (%d) found in memory @ %p (from %p). off_cryptid = %u (0x%x)\n", eic->cryptid, &eic->cryptid, image_mh, off_cryptid, off_cryptid);
			//NSLog(@"[trolldecrypt] Found encrypted data at offset %u 0x%08x. image_mh @ %p. cryptedData @ 0x%x. cryptsize = %u (0x%x) bytes.\n", eic->cryptoff, eic->cryptoff, image_mh, (unsigned int)image_mh + eic->cryptoff, eic->cryptsize, eic->cryptsize);
			
			NSLog(@"[trolldecrypt] Dumping: %s", encryptedImageFilenameStr);
			NSLog(@"[trolldecrypt]    Into: %s", self->decryptedAppPathStr);
			fd = open(encryptedImageFilenameStr, O_RDONLY);
			if (fd == -1) {
				NSLog(@"[trolldecrypt] Failed to open %s", encryptedImageFilenameStr);
				return false;
			}
			
			NSLog(@"[trolldecrypt] Reading header");
			n = read(fd, (void *)buffer, sizeof(buffer));
			if (n != sizeof(buffer)) {
				NSLog(@"[trolldecrypt] Warning read only %d of %lu bytes from encrypted file.\n", n, sizeof(buffer));
				return false;
			}

			NSLog(@"[trolldecrypt] Detecting header type\n");
			fh = (struct fat_header *)buffer;
			
			/* Is this a FAT file - we assume the right endianess */
			if (fh->magic == FAT_CIGAM) {
				NSLog(@"[trolldecrypt] Executable is a FAT image - searching for right architecture\n");
				arch = (struct fat_arch *)&fh[1];
				for (i=0; i<swap32(fh->nfat_arch); i++) {
					if ((image_mh->cputype == swap32(arch->cputype)) && (image_mh->cpusubtype == swap32(arch->cpusubtype))) {
						fileoffs = swap32(arch->offset);
						NSLog(@"[trolldecrypt] Correct arch is at offset 0x%x in the file.\n", fileoffs);
						break;
					}
					arch++;
				}
				if (fileoffs == 0) {
					NSLog(@"[trolldecrypt] Could not find correct arch in FAT image\n");
					return false;
				}
			} else if (fh->magic == MH_MAGIC || fh->magic == MH_MAGIC_64) {
				NSLog(@"[trolldecrypt] Executable is a plain MACH-O image, fileoffs = 0\n");
			} else {
				NSLog(@"[trolldecrypt] Executable is of unknown type, fileoffs = 0\n");
				return false;
			}

            off_cryptid = find_off_cryptid(encryptedImageFilenameStr, fileoffs);
            if (off_cryptid == 0) {
                NSLog(@"[trolldecrypt-v055] missing or invalid disk cryptid command");
                close(fd);
                return false;
            }
			NSLog(@"[trolldecrypt] Opening %s for writing.\n", decryptedAppPathStr);
			outfd = open(decryptedAppPathStr, O_RDWR|O_CREAT|O_TRUNC, 0644);
			if (outfd == -1) {
				NSLog(@"[trolldecrypt] Failed opening: ");
				return false;
			}
			
            // Validate all on-disk offsets BEFORE copying or patching cryptid.
            // A mistaken overflow or truncated input must never create a
            // cryptid=0 IPA whose protected range was not actually recovered.
            off_t fileLength = lseek(fd, 0, SEEK_END);
            uint64_t encryptedStart = (uint64_t)fileoffs + (uint64_t)eic->cryptoff;
            uint64_t encryptedSize = (uint64_t)eic->cryptsize;
            if (fileLength < 0 || encryptedSize == 0 ||
                encryptedStart > (uint64_t)fileLength ||
                encryptedSize > (uint64_t)fileLength - encryptedStart ||
                off_cryptid == 0 ||
                (uint64_t)off_cryptid + sizeof(uint32_t) > (uint64_t)fileLength ||
                lseek(fd, 0, SEEK_SET) != 0) {
                NSLog(@"[trolldecrypt-v055] invalid protected region or cryptid offset");
                close(fd); close(outfd); unlink(decryptedAppPathStr);
                return false;
            }

            BOOL copyOK = v055CopyExactly(fd, outfd, encryptedStart);
            uint64_t remainingEncrypted = encryptedSize;
            uint64_t memoryOffset = 0;
            BOOL plaintextChanged = NO;
            uint8_t ciphertext[65536], plaintext[65536];

            while (copyOK && remainingEncrypted > 0) {
                size_t length = remainingEncrypted > sizeof(plaintext)
                    ? sizeof(plaintext) : (size_t)remainingEncrypted;
                copyOK = v055ReadExact(fd, ciphertext, length) &&
                    readmem((mach_vm_offset_t *)plaintext,
                        (mach_vm_address_t)imageAddress + eic->cryptoff + memoryOffset,
                        length, targetTask, &region_info) == KERN_SUCCESS;
                if (!copyOK) break;
                if (memcmp(ciphertext, plaintext, length) != 0) plaintextChanged = YES;
                copyOK = v055WriteExact(outfd, plaintext, length);
                memoryOffset += length;
                remainingEncrypted -= length;
            }
            // Merely reading memory is NOT enough: a mapped encrypted page may
            // still contain ciphertext. Refuse to produce a fake decrypted IPA.
            if (!plaintextChanged) {
                NSLog(@"[trolldecrypt-v055] protected bytes unchanged; refusing fake cryptid=0");
                copyOK = NO;
            }
            if (copyOK) {
                uint64_t remainder = (uint64_t)fileLength - encryptedStart - encryptedSize;
                copyOK = v055CopyExactly(fd, outfd, remainder);
            }
            if (copyOK) {
                uint32_t clearCryptid = 0;
                copyOK = lseek(outfd, (off_t)off_cryptid, SEEK_SET) == (off_t)off_cryptid &&
                    v055WriteExact(outfd, &clearCryptid, sizeof(clearCryptid));
            }

            close(fd);
            if (close(outfd) != 0) copyOK = NO;
            if (!copyOK) {
                unlink(decryptedAppPathStr);
                NSLog(@"[trolldecrypt-v055] incomplete or unchanged plaintext; output removed");
                return false;
            }
            return true;
		}
		
		lc = (struct load_command *)((unsigned char *)lc+lc->cmdsize);		
        // readmem((mach_vm_offset_t*)lc, lc+lc->cmdsize, header.sizeofcmds, targetTask, &region_info);
	}
	// DEBUG(@"[!] This mach-o file is not encrypted. Nothing was decrypted.\n");
	return false;
}


-(BOOL) dumpDecrypted:(pid_t)pid {

    vm_map_t targetTask = 0;
    if (task_for_pid(mach_task_self(), pid, &targetTask))
    {
        NSLog(@"[trolldecrypt-v045] task_for_pid denied; no output is trusted");
        return NO;
    }

    //numberOfImages
    struct task_dyld_info dyld_info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;

    if (task_info(targetTask, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count) != KERN_SUCCESS ||
        dyld_info.all_image_info_addr == 0) {
        mach_port_deallocate(mach_task_self(), targetTask);
        return NO;
    }

    // V098: read dyld metadata into owned, bounded host buffers. The upstream
    // vm_read() version leaked its returned VM allocation and task rights on
    // early exits. Require exact reads, including the fixed-size metadata.
    struct dyld_all_image_infos dyldSnapshot = {0};
    if (readmem((mach_vm_offset_t *)&dyldSnapshot, dyld_info.all_image_info_addr,
                sizeof(dyldSnapshot), targetTask, NULL) != KERN_SUCCESS ||
        dyldSnapshot.infoArrayCount == 0 || dyldSnapshot.infoArrayCount > 4096 ||
        dyldSnapshot.infoArray == NULL) {
        mach_port_deallocate(mach_task_self(), targetTask);
        return NO;
    }
    uint32_t numberOfImages = dyldSnapshot.infoArrayCount;
    size_t bytes = (size_t)numberOfImages * sizeof(struct dyld_image_info);
    struct dyld_image_info *info = malloc(bytes);
    if (!info) {
        mach_port_deallocate(mach_task_self(), targetTask);
        return NO;
    }
    if (readmem((mach_vm_offset_t *)info,
                (mach_vm_address_t)dyldSnapshot.infoArray, bytes,
                targetTask, NULL) != KERN_SUCCESS) {
        free(info);
        mach_port_deallocate(mach_task_self(), targetTask);
        return NO;
    }
    mach_vm_address_t imageAddress = 0;
    // V045 target-only strict closure: an early abort can map just the main
    // executable. Never emit a convincing-looking partial ChatGPT IPA.
    NSMutableSet<NSString *> *remaining = [NSMutableSet setWithArray:@[
        @"ChatGPT", @"Frameworks/ChatGPT.framework/ChatGPT",
        @"Frameworks/LinkKit.framework/LinkKit",
        @"Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC",
        @"Frameworks/Lottie.framework/Lottie",
        @"Frameworks/OpenAIXPlat.framework/OpenAIXPlat"
    ]];

    NSLog(@"[trolldecrypt] There are %d images mapped.", numberOfImages);

    for (int i = 0; i < numberOfImages; i++) {
        NSLog(@"[trolldecrypt] image %d", i);
        char imagePath[PATH_MAX];
        imageAddress = (mach_vm_address_t)info[i].imageLoadAddress;
        if (!imageAddress || !v097ReadRemotePath(targetTask,
                (mach_vm_address_t)info[i].imageFilePath,
                imagePath, sizeof(imagePath))) {
            NSLog(@"[trolldecrypt-v097] unavailable or unterminated mapped image path");
            continue;
        }
        const char *imageName = imagePath;

        NSLog(@"[trolldecrypt-v046] Inspecting mapped image: %s", imageName);

        NSString *imageFullPath = [NSString stringWithUTF8String:imageName];
        NSString *prefix = [NSString stringWithFormat:@"%@/", [self appPath]];
        if (imageFullPath && [imageFullPath hasPrefix:prefix]) {
            NSString *relative = [imageFullPath substringFromIndex:prefix.length];
            if ([remaining containsObject:relative]) {
                NSLog(@"[trolldecrypt-v045] required image %d: %@", i, relative);
                if (![self dumpDecryptedImage:imageAddress fileName:imageName image:i task: targetTask]) {
                    NSLog(@"[trolldecrypt-v045] incomplete extraction for %@", relative);
                    free(info);
                    mach_port_deallocate(mach_task_self(), targetTask);
                    return NO;
                }
                [remaining removeObject:relative];
            }
        }
    }
    BOOL complete = remaining.count == 0;
    if (!complete) {
        NSLog(@"[trolldecrypt-v045] encrypted startup closure incomplete: %@", remaining);
    }
    free(info);
    mach_port_deallocate(mach_task_self(), targetTask);
    return complete;
}


-(BOOL)fileManager:(NSFileManager *)f shouldProceedAfterError:(BOOL)proceed copyingItemAtPath:(NSString *)path toPath:(NSString *)dest {
	return true;
} 

-(NSString *)IPAPath {
	return [NSString stringWithFormat:@"%@/%@_%@_decrypted.ipa", [self docPath], self.appName, self.appVersion];
}

-(BOOL) createIPAFile:(pid_t)pid {
	NSString *IPAFile = [self IPAPath];
	NSString *appDir  = [self appPath];
	NSString *appCopyDir = [NSString stringWithFormat:@"%@/ipa/Payload/%s", [self docPath], self->appDirName];
	NSString *zipDir = [NSString stringWithFormat:@"%@/ipa", [self docPath]];
	NSFileManager *fm = [[NSFileManager alloc] init];
	NSError *err;

	[fm removeItemAtPath:IPAFile error:nil];
	[fm removeItemAtPath:appCopyDir error:nil];
    // copyItemAtPath requires its destination not to exist. Only create its parent.
    NSString *payloadDir = [appCopyDir stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:payloadDir withIntermediateDirectories:YES attributes:nil error:&err]) {
        NSLog(@"[trolldecrypt-v045] cannot stage Payload directory: %@", err);
        return NO;
    }

	[fm setDelegate:(id<NSFileManagerDelegate>)self];

	NSLog(@"[trolldecrypt] ======== START FILE COPY - IGNORE ANY SANDBOX WARNINGS ========");
	NSLog(@"[trolldecrypt] IPAFile: %@", IPAFile);
	NSLog(@"[trolldecrypt] appDir: %@", appDir);
	NSLog(@"[trolldecrypt] appCopyDir: %@", appCopyDir);
	NSLog(@"[trolldecrypt] zipDir: %@", zipDir);
	
	if (![fm copyItemAtPath:appDir toPath:appCopyDir error:&err]) {
        NSLog(@"[trolldecrypt-v045] failed to stage authorized app: %@", err);
        [fm removeItemAtPath:zipDir error:nil];
        return NO;
    }
	NSLog(@"[trolldecrypt] ======== END OF FILE COPY ========");
    // sleep(1);
    // exit(1);
	// Replace encrypted binaries with decrypted versions
	NSLog(@"[trolldecrypt] ======== START DECRYPTION PROCESS ========");
	if (![self dumpDecrypted:pid]) {
        NSLog(@"[trolldecrypt-v045] FAIL_CLOSED: six-image startup closure not fully decrypted");
        [fm removeItemAtPath:zipDir error:nil];
        return NO;
    }
	NSLog(@"[trolldecrypt] ======== DECRYPTION COMPLETE  ========");

	// ZIP it up
	NSLog(@"[trolldecrypt] ======== STARTING ZIP ========");
	NSLog(@"[trolldecrypt] IPA file: %@", IPAFile);
	NSLog(@"[trolldecrypt] ZIP dir: %@", zipDir);
	unlink([IPAFile UTF8String]);
    BOOL zipSuccess = NO;
	@try {
		zipSuccess = [SSZipArchive createZipFileAtPath:IPAFile 
										withContentsOfDirectory:zipDir
										keepParentDirectory:NO 
										compressionLevel:1
										password:nil
										AES:NO
										progressHandler:nil
		];
		NSLog(@"[trolldecrypt] ========  ZIP operation complete: %s ========", (zipSuccess)?"success":"failed");
	}
	@catch(NSException *e) {
		NSLog(@"[trolldecrypt] BAAAAAAAARF during ZIP operation!!! , %@", e);
	}
	

	// Clean up. Leave only the .ipa file.
	[fm removeItemAtPath:zipDir error:nil];

    if (!zipSuccess) {
        [fm removeItemAtPath:IPAFile error:nil];
        return NO;
    }
	NSLog(@"[trolldecrypt-v045] archive staged: %@ (independent V023 gate still required)", [self IPAPath]);
	return YES;
}

@end