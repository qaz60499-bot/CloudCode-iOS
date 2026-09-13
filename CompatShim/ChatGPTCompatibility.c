#include <stddef.h>
#include <stdint.h>

#if defined(__has_attribute)
#  if __has_attribute(swiftcall)
#    define SWIFTCALL __attribute__((swiftcall))
#  else
#    define SWIFTCALL
#  endif
#else
#  define SWIFTCALL
#endif

#if defined(__has_feature)
#  if __has_feature(ptrauth_calls)
#    include <ptrauth.h>
#    define HAVE_PTRAUTH_INTRINSICS 1
#  endif
#endif

#define EXPORT __attribute__((visibility("default")))

typedef struct {
    const void *Value;
    uintptr_t State;
} MetadataResponseCompat;

/* iOS 16-era Swift runtime entry points. */
extern const void *swift_conformsToProtocol(const void *typeMetadata,
                                            const void *protocolDescriptor);
extern SWIFTCALL MetadataResponseCompat swift_getOpaqueTypeMetadata(
    uintptr_t request,
    const void * const *arguments,
    const void *descriptor,
    uintptr_t index);
extern SWIFTCALL const void *swift_getOpaqueTypeConformance(
    const void * const *arguments,
    const void *descriptor,
    uintptr_t index);
extern SWIFTCALL const void *swift_getTypeByMangledNameInContext(
    const char *typeNameStart,
    size_t typeNameLength,
    const void *context,
    const void * const *genericArgs);
extern SWIFTCALL const void *swift_getTypeByMangledNameInContextInMetadataState(
    size_t metadataState,
    const char *typeNameStart,
    size_t typeNameLength,
    const void *context,
    const void * const *genericArgs);

/*
 * The iOS 17-generation ...2 entry points differ by accepting signed Swift
 * descriptors.  The older entry points accept the corresponding unsigned
 * descriptor and perform their own signing before entering the shared runtime
 * implementation.  Strip the incoming data PAC before forwarding.
 *
 * The fallback inline xpacd is intentionally device-local: the target device
 * is iPhone14,2 (A15 / arm64e-capable).  It is never injected system-wide.
 */
static inline const void *compat_strip_descriptor(const void *ptr) {
    if (!ptr) return ptr;
#if defined(HAVE_PTRAUTH_INTRINSICS)
    return ptrauth_strip(ptr, ptrauth_key_process_independent_data);
#elif defined(__aarch64__)
    uintptr_t raw = (uintptr_t)ptr;
    __asm__ volatile("xpacd %0" : "+r"(raw));
    return (const void *)raw;
#else
    return ptr;
#endif
}

EXPORT const void *swift_conformsToProtocol2(const void *typeMetadata,
                                              const void *protocolDescriptor) {
    return swift_conformsToProtocol(typeMetadata,
                                    compat_strip_descriptor(protocolDescriptor));
}

EXPORT SWIFTCALL MetadataResponseCompat swift_getOpaqueTypeMetadata2(
    uintptr_t request,
    const void * const *arguments,
    const void *descriptor,
    uintptr_t index) {
    return swift_getOpaqueTypeMetadata(request, arguments,
                                       compat_strip_descriptor(descriptor), index);
}

EXPORT SWIFTCALL const void *swift_getOpaqueTypeConformance2(
    const void * const *arguments,
    const void *descriptor,
    uintptr_t index) {
    return swift_getOpaqueTypeConformance(arguments,
                                          compat_strip_descriptor(descriptor), index);
}

EXPORT SWIFTCALL const void *swift_getTypeByMangledNameInContext2(
    const char *typeNameStart,
    size_t typeNameLength,
    const void *context,
    const void * const *genericArgs) {
    return swift_getTypeByMangledNameInContext(
        typeNameStart, typeNameLength, compat_strip_descriptor(context), genericArgs);
}

EXPORT SWIFTCALL const void *swift_getTypeByMangledNameInContextInMetadataState2(
    size_t metadataState,
    const char *typeNameStart,
    size_t typeNameLength,
    const void *context,
    const void * const *genericArgs) {
    return swift_getTypeByMangledNameInContextInMetadataState(
        metadataState, typeNameStart, typeNameLength,
        compat_strip_descriptor(context), genericArgs);
}
