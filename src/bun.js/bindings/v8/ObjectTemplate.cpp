#include "v8/ObjectTemplate.h"
#include "v8/InternalFieldObject.h"
#include "v8/GlobalInternals.h"

using JSC::JSGlobalObject;
using JSC::JSValue;
using JSC::Structure;

namespace v8 {

// for CREATE_METHOD_TABLE
namespace JSCastingHelpers = JSC::JSCastingHelpers;

const JSC::ClassInfo ObjectTemplate::s_info = {
    "ObjectTemplate"_s,
    &JSC::InternalFunction::s_info,
    nullptr,
    nullptr,
    CREATE_METHOD_TABLE(ObjectTemplate)
};

Local<ObjectTemplate> ObjectTemplate::New(Isolate* isolate, Local<FunctionTemplate> constructor)
{
    RELEASE_ASSERT(constructor.IsEmpty());
    auto globalObject = isolate->globalObject();
    auto& vm = globalObject->vm();
    Structure* structure = globalObject->V8GlobalInternals()->objectTemplateStructure(globalObject);
    auto* objectTemplate = new (NotNull, JSC::allocateCell<ObjectTemplate>(vm)) ObjectTemplate(vm, structure);
    // TODO pass constructor
    objectTemplate->finishCreation(vm);
    return isolate->currentHandleScope()->createLocal<ObjectTemplate>(objectTemplate);
}

MaybeLocal<Object> ObjectTemplate::NewInstance(Local<Context> context)
{
    // TODO handle constructor
    // TODO handle interceptors?

    auto& vm = context->vm();

    // get a structure
    if (!internals().objectStructure) {
        auto structure = JSC::Structure::create(
            vm,
            context->globalObject(),
            context->globalObject()->objectPrototype(),
            JSC::TypeInfo(JSC::ObjectType, InternalFieldObject::StructureFlags),
            InternalFieldObject::info());
        internals().objectStructure.set(context->vm(), this, structure);
    }
    auto structure = internals().objectStructure.get();

    // create object from it
    // examine in debugger, but the `this` here comes from the Local so it should be okay with
    // any public functions InternalFieldObject calls
    auto newInstance = InternalFieldObject::create(vm, structure, this);

    // todo: apply properties

    return MaybeLocal<Object>(context->currentHandleScope()->createLocal<Object>(newInstance));
}

void ObjectTemplate::SetInternalFieldCount(int value)
{
    internals().internalFieldCount = value;
}

Structure* ObjectTemplate::createStructure(JSC::VM& vm, JSGlobalObject* globalObject, JSValue prototype)
{
    return Structure::create(
        vm,
        globalObject,
        prototype,
        JSC::TypeInfo(JSC::InternalFunctionType, StructureFlags),
        info());
}

JSC::EncodedJSValue ObjectTemplate::DummyCallback(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    ASSERT_NOT_REACHED();
    return JSC::JSValue::encode(JSC::jsUndefined());
}

}
