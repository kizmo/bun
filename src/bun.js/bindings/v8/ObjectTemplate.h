#pragma once

#include "JavaScriptCore/SubspaceAccess.h"
#include "v8.h"
#include "v8/Context.h"
#include "v8/Local.h"
#include "v8/Isolate.h"
#include "v8/FunctionTemplate.h"
#include "v8/MaybeLocal.h"
#include "v8/Object.h"

namespace v8 {

// matches V8 class hierarchy
class Template : public Data {};

class ObjectTemplate : public JSC::InternalFunction, public Template {
public:
    DECLARE_INFO;

    BUN_EXPORT static Local<ObjectTemplate> New(Isolate* isolate, Local<FunctionTemplate> constructor = Local<FunctionTemplate>());
    BUN_EXPORT MaybeLocal<Object> NewInstance(Local<Context> context);
    BUN_EXPORT void SetInternalFieldCount(int value);
    BUN_EXPORT int InternalFieldCount() const;

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype);

    template<typename, JSC::SubspaceAccess mode>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<ObjectTemplate, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForObjectTemplate.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForObjectTemplate = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForObjectTemplate.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForObjectTemplate = std::forward<decltype(space)>(space); });
    }

    DECLARE_VISIT_CHILDREN;

private:
    class Internals {
        int internalFieldCount = 0;
        JSC::LazyProperty<ObjectTemplate, JSC::Structure> objectStructure;
        friend class ObjectTemplate;
    };

    // do not use directly inside exported V8 functions, use internals()
    Internals __internals;

    Internals& internals()
    {
        ObjectTemplate* thisObj = Data::locationToObjectPointer<ObjectTemplate>(this);
        return thisObj->__internals;
    }

    const Internals& internals() const
    {
        const ObjectTemplate* thisObj = Data::locationToObjectPointer<ObjectTemplate>(this);
        return thisObj->__internals;
    }

    static JSC_HOST_CALL_ATTRIBUTES JSC::EncodedJSValue DummyCallback(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame);

    ObjectTemplate(JSC::VM& vm, JSC::Structure* structure)
        : JSC::InternalFunction(vm, structure, DummyCallback, DummyCallback)
    {
    }

    void finishCreation(JSC::VM& vm);
};

}
