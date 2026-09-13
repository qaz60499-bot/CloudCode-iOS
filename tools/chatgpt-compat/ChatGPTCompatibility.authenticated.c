/*
 * Authenticated Swift signed-descriptor compatibility adapter for iOS 16.6.
 * Process-local compatibility shim source only.
 */
#include <stddef.h>
#include <stdint.h>
#include <ptrauth.h>

#if !defined(__has_feature) || !__has_feature(ptrauth_intrinsics)
#error "ptrauth intrinsics are required; do not silently degrade"
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

static inline const void *auth_data_descriptor(const void *pointer, uintptr_t discriminator) {
    if (!pointer) return pointer;
    return ptrauth_auth_data(
        pointer,
        ptrauth_key_process_independent_data,
        (ptrauth_extra_data_t)discriminator);
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
