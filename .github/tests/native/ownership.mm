#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"
#include "4DPlugin-Dock.cpp"
#include "support/4DPlugin-JSON.cpp"
#include "ARRAY_TEXT.h"

static void check(bool ok, const char *message) {
    if(!ok) {
        fprintf(stderr, "ownership regression: %s\n", message);
        std::exit(1);
    }
}

using Text = std::basic_string<PA_Unichar>;
static std::map<PA_Unichar *, size_t> strings;
static std::map<PA_Handle, size_t> handles;
struct Ref {
    int owners = 1;
    std::map<Text, PA_Variable> properties;
};
static std::map<void *, Ref *> refs;
static bool nullEmpty = false;
static bool methodExists = true;
static bool getterFails = false;
static bool failHandle = false;
static Text expectedMethod;
static PA_Variable callbackResult;
static int calls = 0;
static int variableClears = 0;

static Text text(PA_Unistring s) {
    PA_Unichar *p = s.fString;
    check(s.fLength >= 0, "negative text length");
    if(!s.fString) {
        check(s.fLength == 0, "null nonempty text");
        return {};
    }
    check(strings.count(p), "borrowed text outlived its owner");
    check(strings.at(p) == size_t(s.fLength), "exact UTF-16 length");
    check(s.fString[s.fLength] == 0, "UTF-16 terminator");
    return Text(s.fString, s.fLength);
}

static PA_Unistring makeString(const Text &t) {
    PA_Unistring s = {};
    if(nullEmpty && t.empty())
        return s;
    s.fLength = PA_long32(t.size());
    s.fString = static_cast<PA_Unichar *>(malloc((t.size() + 1) * sizeof(PA_Unichar)));
    check(s.fString, "fixture string allocation");
    memcpy(s.fString, t.c_str(), (t.size() + 1) * sizeof(PA_Unichar));
    PA_Unichar *p = s.fString;
    strings.emplace(p, t.size());
    return s;
}

static void freeString(PA_Unistring s) {
    if(s.fString) {
        text(s);
        PA_Unichar *p = s.fString;
        check(strings.erase(p) == 1, "string disposed twice");
        free(s.fString);
    }
}

static void *newRef() {
    Ref *r = new Ref;
    refs.emplace(r, r);
    return r;
}

static void clear(PA_Variable &v);
static void release(void *p) {
    if(!p) return;
    check(refs.count(p), "reference disposed twice");
    Ref *r = refs.at(p);
    if(--r->owners == 0) {
        for(auto &entry : r->properties)
            clear(entry.second);
        refs.erase(p);
        delete r;
    }
}

static PA_Variable copy(PA_Variable v) {
    if(v.fType == eVK_Unistring)
        v.uValue.fString = makeString(text(v.uValue.fString));
    else if(v.fType == eVK_Object || v.fType == eVK_Collection || v.fType == eVK_Picture) {
        void *p = v.fType == eVK_Object ? v.uValue.fObject :
            v.fType == eVK_Collection ? v.uValue.fCollection : v.uValue.fPicture;
        if(p) {
            check(refs.count(p), "copy of dead reference");
            ++refs.at(p)->owners;
        }
    }
    return v;
}

static void clear(PA_Variable &v) {
    switch(v.fType) {
        case eVK_Unistring: freeString(v.uValue.fString); break;
        case eVK_Object: release(v.uValue.fObject); break;
        case eVK_Collection: release(v.uValue.fCollection); break;
        case eVK_Picture: release(v.uValue.fPicture); break;
        case eVK_ArrayUnicode:
            if(v.uValue.fArray.fData) {
                auto h = v.uValue.fArray.fData;
                check(handles.count(h), "clear of dead array handle");
                check(handles.at(h) == (v.uValue.fArray.fNbElements + 1) * sizeof(PA_Unistring),
                      "array byte capacity");
                auto p = reinterpret_cast<PA_Unistring *>(*h);
                for(int i = 0; i <= v.uValue.fArray.fNbElements; ++i)
                    freeString(p[i]);
                free(*h);
                free(h);
                handles.erase(h);
            }
            break;
        case eVK_Undefined: case eVK_Null: case eVK_Longint:
        case eVK_Boolean: case eVK_Real: break;
        default: check(false, "unexpected variable kind in clear");
    }
    v = {};
    v.fType = eVK_Undefined;
}

static void engine(short selector, EngineBlock *eb) {
    eb->fError = eER_NoErr;
    switch(selector) {
        case EX_CREATE_UNISTRING:
            eb->fUniString1 = makeString(Text(reinterpret_cast<PA_Unichar *>(eb->fHandle)));
            return;
        case EX_DISPOSE_UNISTRING: freeString(eb->fUniString1); return;
        case EX_VARIABLE_TO_STRING: {
            check(!getterFails, "failed getter output inspected");
            auto v = reinterpret_cast<PA_Variable *>(eb->fHandle);
            check(v->fType == eVK_Unistring, "string getter kind");
            eb->fUniString1 = v->uValue.fString;
            return;
        }
        case EX_SET_UNISTRING: {
            Text t(reinterpret_cast<PA_Unichar *>(eb->fHandle));
            freeString(eb->fUniString1);
            eb->fUniString1 = makeString(t);
            return;
        }
        case EX_CLEAR_VARIABLE:
            ++variableClears;
            clear(*static_cast<PA_Variable *>(eb->fPtr1));
            return;
        case EX_HANDLE_MANAGER: {
            auto h = eb->fHandle;
            switch(eb->fParam1) {
                case 1:
                    if(failHandle) {
                        eb->fHandle = nullptr;
                        eb->fError = eER_NotEnoughMemory;
                        return;
                    }
                    h = static_cast<PA_Handle>(malloc(sizeof(char *)));
                    *h = static_cast<char *>(calloc(size_t(eb->fParam2) + 1, 1));
                    handles.emplace(h, size_t(eb->fParam2));
                    eb->fHandle = h;
                    return;
                case 2:
                    check(handles.erase(h) == 1, "handle disposed twice");
                    free(*h); free(h); return;
                case 3:
                    check(handles.count(h), "resize dead handle");
                    *h = static_cast<char *>(realloc(*h, size_t(eb->fParam2) + 1));
                    handles[h] = size_t(eb->fParam2); return;
                case 4: eb->fParam2 = handles.at(h); return;
                case 5: eb->fParam3 = reinterpret_cast<sLONG_PTR>(*h); return;
                case 6: return;
                default: check(false, "unexpected handle operation");
            }
            return;
        }
        case EX_GET_METHOD_ID:
            check(Text(eb->fUName) == expectedMethod, "exact callback method name");
            eb->fParam1 = methodExists ? 42 : 0;
            return;
        case EX_CALL_BY_PROCID: {
            check(eb->fParam1 == 42 && eb->fParam2 == 0, "unchanged method arity");
            auto vars = reinterpret_cast<PA_Variable *>(*eb->fHandle);
            vars[0] = copy(callbackResult);
            ++calls;
            return;
        }
        case EX_EXECUTE_COMMAND_BY_ID: {
            auto params = static_cast<PA_Variable **>(eb->fPtr1);
            auto result = static_cast<PA_Variable *>(eb->fPtr2);
            if(eb->fParam1 == 1007) {
                check(eb->fParam2 == 1, "unchanged EXECUTE METHOD arity");
                check(text(params[0]->uValue.fString) == expectedMethod, "fallback method argument");
                *result = copy(callbackResult);
                ++calls;
            } else if(eb->fParam1 == 1231) {
                auto r = refs.at(static_cast<void *>(params[0]->uValue.fObject));
                PA_SetBooleanVariable(result, r->properties.count(text(params[1]->uValue.fString)));
            } else {
                check(false, "unexpected command");
            }
            return;
        }
        case EX_GET_OBJ_VALUE: {
            if(getterFails) {
                // Poisoned output: failure must not be interpreted or cleared.
                memset(eb->fPtr2, 0xA5, sizeof(PA_Variable));
                static_cast<PA_Variable *>(eb->fPtr2)->fType = eVK_Unistring;
                eb->fError = eER_NotEnoughMemory;
                return;
            }
            auto r = refs.at(static_cast<void *>(eb->fPtr1));
            *static_cast<PA_Variable *>(eb->fPtr2) = copy(r->properties.at(text(eb->fUniString1)));
            return;
        }
        case EX_SET_OBJ_VALUE: {
            auto r = refs.at(static_cast<void *>(eb->fPtr1));
            Text key = text(eb->fUniString1);
            if(r->properties.count(key)) clear(r->properties.at(key));
            r->properties[key] = copy(*static_cast<PA_Variable *>(eb->fPtr2));
            return;
        }
        case EX_CREATE_PICTURE: eb->fPicture = newRef(); return;
        case EX_DISPOSE_PICTURE: release(eb->fPicture); return;
        default:
            fprintf(stderr, "unexpected engine selector: %d\n", selector);
            std::exit(1);
    }
}

static Text utf16(const char16_t *s) {
    return Text(reinterpret_cast<const PA_Unichar *>(s));
}

static std::vector<Text> fixtures() {
    return {utf16(u"ASCII"), utf16(u"\u65e5\u672c"), utf16(u"A\U0001f600Z"), {}};
}

static void balanced(const char *label) {
    if(!strings.empty() || !handles.empty() || !refs.empty()) {
        fprintf(stderr, "%s: strings=%zu handles=%zu refs=%zu\n",
                label, strings.size(), handles.size(), refs.size());
        check(false, label);
    }
}

static void callback(bool fallback, bool emptyReturn, bool refReturn, bool undefinedReturn = false) {
    methodExists = !fallback;
    for(const auto &f : fixtures()) {
        if(f.empty()) continue;
        expectedMethod = f;
        DOCK::LISTENER_METHOD.setUTF16String(f.c_str(), uint32_t(f.size()));
        callbackResult = PA_CreateVariable(eVK_Undefined);
        if(refReturn)
            PA_SetObjectVariable(&callbackResult, newRef());
        else if(!undefinedReturn) {
            PA_Unistring s = makeString(emptyReturn ? Text() : f);
            PA_SetStringVariable(&callbackResult, &s);
        }
        for(int i = 0; i < 10; ++i) {
            DOCK::CALLBACK_EVENT_IDS.push_back(1);
            listenerLoopExecuteMethod();
        }
        PA_ClearVariable(&callbackResult);
        balanced(fallback ? "callback-fallback-ownership" : "callback-method-result");
    }
    check(calls == 30, "repeated callbacks");
    DOCK::LISTENER_METHOD.setUTF16String(utf16(u"").c_str(), 0);
    DOCK::CALLBACK_EVENT_IDS.push_back(1);
    listenerLoopExecuteMethod();
    check(calls == 30, "empty callback name does not execute");
}

static void callbackHandleFailure() {
    expectedMethod = utf16(u"onDock");
    DOCK::LISTENER_METHOD.setUTF16String(expectedMethod.c_str(), uint32_t(expectedMethod.size()));
    for(bool fallback : {false, true}) {
        methodExists = !fallback;
        failHandle = true;
        DOCK::CALLBACK_EVENT_IDS.push_back(1);
        listenerLoopExecuteMethod();
        failHandle = false;
        check(calls == 0, "failed invocation handle must not call engine");
        balanced("callback-handle-allocation-failure");
    }
}

static void setters() {
    auto obj = newRef();
    for(const auto &f : fixtures()) {
        C_TEXT s;
        s.setUTF16String(f.c_str(), uint32_t(f.size()));
        CUTF8String u8;
        s.copyUTF8String(&u8);
        ob_set_s(obj, "value", reinterpret_cast<const char *>(u8.c_str()));
        check(text(refs.at(obj)->properties.at(utf16(u"value")).uValue.fString) == f,
              "narrow JSON setter exact content");
        ob_set_s(obj, L"value", reinterpret_cast<const char *>(u8.c_str()));
        check(text(refs.at(obj)->properties.at(utf16(u"value")).uValue.fString) == f,
              "wide JSON setter exact content");
        ob_set_a(obj, L"value", &f);
        check(text(refs.at(obj)->properties.at(utf16(u"value")).uValue.fString) == f,
              "UTF-16 JSON setter exact content");
    }
    ob_set_a(obj, L"value", L"A\u65e5\U0001f600");
    check(text(refs.at(obj)->properties.at(utf16(u"value")).uValue.fString) ==
          utf16(u"A\u65e5\U0001f600"), "wchar JSON setter exact content");
    ob_set_p(obj, L"picture", newRef());
    PA_DisposeObject(obj);
    balanced("json-setter-empty-overwrite");
}

static void getters(const std::string &mode) {
    auto obj = newRef();
    for(const auto &f : fixtures()) {
        PA_Variable v = PA_CreateVariable(eVK_Undefined);
        PA_Unistring s = makeString(f);
        PA_SetStringVariable(&v, &s);
        refs.at(obj)->properties[utf16(u"value")] = v;
        CUTF8String result;
        if(mode == "get-text") {
            check(ob_get_a(obj, L"value", &result), "existing JSON property");
            C_TEXT decoded;
            decoded.setUTF8String(&result);
            check(Text(decoded.getUTF16StringPtr(), decoded.getUTF16Length()) == f,
                  "copied getter exact content");
        } else {
            getterFails = mode == "get-failed";
            ob_get_a(obj, L"value", &result);
            check(!ob_get_b(obj, L"value"), "boolean mismatch default");
            check(ob_get_n(obj, L"value") == 0, "real mismatch default");
            check(ob_get_c(obj, L"value") == nullptr, "collection mismatch default");
            check(ob_get_o(obj, L"value") == nullptr, "object mismatch default");
        }
        PA_ClearVariable(&refs.at(obj)->properties.at(utf16(u"value")));
        refs.at(obj)->properties.clear();
    }
    PA_DisposeObject(obj);
    balanced(mode.c_str());
}

static void handoffs() {
    auto obj = newRef();
    PA_Variable child = PA_CreateVariable(eVK_Undefined);
    PA_SetObjectVariable(&child, newRef());
    refs.at(obj)->properties[utf16(u"object")] = child;
    PA_SetCollectionVariable(&child, newRef());
    refs.at(obj)->properties[utf16(u"collection")] = child;
    auto o = ob_get_o(obj, L"object");
    auto c = ob_get_c(obj, L"collection");
    check(refs.at(o)->owners == 2 && refs.at(c)->owners == 2, "owning reference handoffs");
    PA_DisposeObject(obj);
    check(refs.at(o)->owners == 1 && refs.at(c)->owners == 1, "handoff survives parent clear");
    PA_DisposeObject(o);
    PA_DisposeCollection(c);
    balanced("owning-handoffs");
}

static void getterKinds() {
    auto obj = newRef();
    for(auto kind : {eVK_Boolean, eVK_Real, eVK_Object, eVK_Collection}) {
        PA_Variable v = PA_CreateVariable(eVK_Undefined);
        if(kind == eVK_Boolean) PA_SetBooleanVariable(&v, true);
        if(kind == eVK_Real) PA_SetRealVariable(&v, 3.25);
        if(kind == eVK_Object) PA_SetObjectVariable(&v, newRef());
        if(kind == eVK_Collection) PA_SetCollectionVariable(&v, newRef());
        refs.at(obj)->properties[utf16(u"value")] = v;
        int before = variableClears;
        if(kind == eVK_Boolean) {
            check(ob_get_b(obj, L"value"), "boolean value survives clear");
            check(variableClears == before + 1, "successful boolean getter result cleared");
        }
        if(kind == eVK_Real) {
            check(ob_get_n(obj, L"value") == 3.25, "real value survives clear");
            check(variableClears == before + 1, "successful real getter result cleared");
        }
        if(kind == eVK_Object || kind == eVK_Collection) {
            CUTF8String value;
            ob_get_a(obj, L"value", &value);
            ob_get_b(obj, L"value");
            ob_get_n(obj, L"value");
            if(kind == eVK_Object)
                check(!ob_get_c(obj, L"value"), "object/collection mismatch");
            else
                check(!ob_get_o(obj, L"value"), "collection/object mismatch");
        }
        PA_ClearVariable(&refs.at(obj)->properties.at(utf16(u"value")));
        refs.at(obj)->properties.clear();
    }
    PA_DisposeObject(obj);
    balanced("getter-kind-mismatch-reference-release");
}

static void arrays() {
    PA_Variable arr = PA_CreateVariable(eVK_ArrayUnicode);
    PackagePtr params = reinterpret_cast<PackagePtr>(calloc(1, sizeof(void *)));
    params[0] = reinterpret_cast<BytePtr>(&arr);
    {
        ARRAY_TEXT out;
        for(const auto &f : fixtures())
            out.appendUTF16String(f.c_str(), uint32_t(f.size()));
        out.toParamAtIndex(params, 1);
        ARRAY_TEXT borrowedCopy;
        borrowedCopy.fromParamAtIndex(params, 1);
        out.toParamAtIndex(params, 1);
        for(size_t i = 0; i < fixtures().size(); ++i) {
            check(text(PA_GetStringInArray(arr, PA_long32(i))) == fixtures()[i],
                  "array transfer content");
            CUTF16String copied;
            borrowedCopy.copyUTF16StringAtIndex(&copied, uint32_t(i));
            check(copied == fixtures()[i], "borrowed copy survives replacement");
        }
        out.setSize(2);
        out.toParamAtIndex(params, 1);
        PA_ClearVariable(&arr);
        arr = PA_CreateVariable(eVK_Undefined);
        out.toParamAtIndex(params, 1);
        PA_ClearVariable(&arr);
    }
    free(params);
    arr = PA_CreateVariable(eVK_ArrayUnicode);
    PA_ResizeArray(&arr, 1);
    auto a = makeString(utf16(u"same"));
    auto b = makeString(utf16(u"same"));
    check(a.fString != b.fString, "independent accepted transfer owners");
    PA_SetStringInArray(arr, 0, &a);
    PA_SetStringInArray(arr, 1, &b);
    for(int i : {-1, 2}) {
        auto rejected = makeString(utf16(u"rejected"));
        PA_SetStringInArray(arr, i, &rejected);
        check(text(rejected) == utf16(u"rejected"), "rejected index retains ownership");
        PA_DisposeUnistring(&rejected);
    }
    auto rejected = makeString(utf16(u"rejected"));
    PA_Variable wrong = PA_CreateVariable(eVK_Longint);
    PA_SetStringInArray(wrong, 0, &rejected);
    PA_Variable missing = {};
    missing.fType = eVK_ArrayUnicode;
    PA_SetStringInArray(missing, 0, &rejected);
    check(text(rejected) == utf16(u"rejected"), "wrong type/null data retains ownership");
    PA_DisposeUnistring(&rejected);
    PA_SetStringInArray(arr, 0, nullptr);
    check(text(PA_GetStringInArray(arr, 0)) == utf16(u"same"), "null descriptor rejects");
    PA_ResizeArray(&arr, 0);
    PA_ClearVariable(&arr);
    balanced("array-transfers");
}

static void contentSetters() {
    for(const auto &f : fixtures()) {
        PA_Unistring source = makeString(f);
        PackagePtr params = reinterpret_cast<PackagePtr>(calloc(1, sizeof(void *)));
        params[0] = reinterpret_cast<BytePtr>(&source);
        C_TEXT s;
        s.fromParamAtIndex(params, 1);
        PA_DisposeUnistring(&source);
        PA_Unistring output = makeString(utf16(u"old"));
        params[0] = reinterpret_cast<BytePtr>(&output);
        s.toParamAtIndex(params, 1);
        check(text(output) == f, "parameter content setter");
        PA_Unistring *result = &output;
        s.setReturn(reinterpret_cast<sLONG_PTR *>(&result));
        check(text(output) == f, "return content setter");
        PluginBlock p = {};
        p.fResult = &result;
        PA_ReturnString(&p, const_cast<PA_Unichar *>(f.c_str()));
        check(text(output) == f, "SDK return content setter");
        DOCK::LISTENER_METHOD.setUTF16String(f.c_str(), uint32_t(f.size()));
        FourDPackex(2, nullptr, nullptr, &result);
        check(text(output) == f, "export/dispatcher method return");
        PA_DisposeUnistring(&output);
        free(params);
    }
    balanced("content-setters");
}

int main(int argc, char **argv) {
    check(argc == 3, "case and empty representation required");
    gCall4D = engine;
    nullEmpty = std::string(argv[2]) == "null";
    std::string mode(argv[1]);
    @autoreleasepool {
        if(mode == "callback-method") callback(false, false, false);
        else if(mode == "callback-fallback") callback(true, false, false);
        else if(mode == "callback-empty") callback(false, true, false);
        else if(mode == "callback-ref") callback(false, false, true);
        else if(mode == "callback-noresult") callback(true, false, false, true);
        else if(mode == "callback-handle-failure") callbackHandleFailure();
        else if(mode == "setters") setters();
        else if(mode == "get-text" || mode == "get-mismatch" || mode == "get-failed") getters(mode);
        else if(mode == "handoffs") handoffs();
        else if(mode == "getter-kinds") getterKinds();
        else if(mode == "arrays") arrays();
        else if(mode == "content") contentSetters();
        else check(false, "unknown test case");
    }
    printf("PASS %s (%s empty), strings=0 handles=0 refs=0\n", argv[1], argv[2]);
}
