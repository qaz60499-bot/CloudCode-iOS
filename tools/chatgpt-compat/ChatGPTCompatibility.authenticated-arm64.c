/*
 * Authenticated Swift signed-descriptor compatibility adapter for an arm64
 * subtype-0 Mach-O slice on ARMv8.3-A hardware.
 *
 * Unlike the historical XPACD-only bridge, this explicitly executes AUTDA and
 * traps if authentication did not yield a canonical stripped data pointer.
 */
#include <stddef.h>
#include <stdint.h>

#if !defined(__aarch64__) && !defined(__arm64__)
#error "arm64 target required"
#endif

#if defined(__has_attribute)
#  if __has_attribute(swiftcall)
#    define SWIFT_CC __attribute__((swiftcall))
#  else
#    error "Apple Clang swiftcall attribute is required"
#  endif
#else
#  error "Compiler attribute detection is required"
#endif

typedef struct {
    const void *value;
    uintptr_t state;
} MetadataResponseCompat;

enum {
    SWIFT_PTRAUTH_PROTOCOL_DESCRIPTOR = 0xe909,
    SWIFT_PTRAUTH_OPAQUE_TYPE_DESCRIPTOR = 0xbdd1,
    SWIFT_PTRAUTH_CONTEXT_DESCRIPTOR = 0xb5e3,
};

extern const void *swift_conformsToProtocol(const void *type, const void *protocol);
extern SWIFT_CC MetadataResponseCompat swift_getOpaqueTypeMetadata(
    uintptr_t request,
    const void *const *arguments,
    const void *descriptor,
    uintptr_t index);
extern SWIFT_CC const void *swift_getOpaqueTypeConformance(
    const void *const *arguments,
    const void *descriptor,
    uintptr_t index);
extern SWIFT_CC const void *swift_getTypeByMangledNameInContext(
    const char *typeNameStart,
    size_t typeNameLength,
    const void *context,
    const void *const *genericArgs);
extern SWIFT_CC const void *swift_getTypeByMangledNameInContextInMetadataState(
    uintptr_t metadataState,
    const char *typeNameStart,
    size_t typeNameLength,
    const void *context,
    const void *const *genericArgs);

static __attribute__((always_inline)) inline const void *auth_data_descriptor(
    const void *pointer,
    uintptr_t discriminator) {
    if (!pointer) return pointer;

    uintptr_t authenticated = (uintptr_t)pointer;
    uintptr_t canonical;
    __asm__ volatile(
        "autda %x0, %x2\n\t"
        "mov %x1, %x0\n\t"
        "xpacd %x1\n\t"
        "cmp %x0, %x1\n\t"
        "b.eq 1f\n\t"
        "brk #0xc472\n"
        "1:"
        : "+r"(authenticated), "=&r"(canonical)
        : "r"(discriminator)
        : "cc");
    return (const void *)authenticated;
}

const void *swift_conformsToProtocol2(const void *type, const void *signedProtocol) {
    const void *protocol = auth_data_descriptor(
        signedProtocol, SWIFT_PTRAUTH_PROTOCOL_DESCRIPTOR);
    return swift_conformsToProtocol(type, protocol);
}

SWIFT_CC MetadataResponseCompat swift_getOpaqueTypeMetadata2(
    uintptr_t request,
    const void *const *arguments,
    const void *signedDescriptor,
    uintptr_t index) {
    const void *descriptor = auth_data_descriptor(
        signedDescriptor, SWIFT_PTRAUTH_OPAQUE_TYPE_DESCRIPTOR);
    return swift_getOpaqueTypeMetadata(request, arguments, descriptor, index);
}

SWIFT_CC const void *swift_getOpaqueTypeConformance2(
    const void *const *arguments,
    const void *signedDescriptor,
    uintptr_t index) {
    const void *descriptor = auth_data_descriptor(
        signedDescriptor, SWIFT_PTRAUTH_OPAQUE_TYPE_DESCRIPTOR);
    return swift_getOpaqueTypeConformance(arguments, descriptor, index);
}

SWIFT_CC const void *swift_getTypeByMangledNameInContext2(
    const char *typeNameStart,
    size_t typeNameLength,
    const void *signedContext,
    const void *const *genericArgs) {
    const void *context = auth_data_descriptor(
        signedContext, SWIFT_PTRAUTH_CONTEXT_DESCRIPTOR);
    return swift_getTypeByMangledNameInContext(
        typeNameStart, typeNameLength, context, genericArgs);
}

SWIFT_CC const void *swift_getTypeByMangledNameInContextInMetadataState2(
    uintptr_t metadataState,
    const char *typeNameStart,
    size_t typeNameLength,
    const void *signedContext,
    const void *const *genericArgs) {
    const void *context = auth_data_descriptor(
        signedContext, SWIFT_PTRAUTH_CONTEXT_DESCRIPTOR);
    return swift_getTypeByMangledNameInContextInMetadataState(
        metadataState, typeNameStart, typeNameLength, context, genericArgs);
}
