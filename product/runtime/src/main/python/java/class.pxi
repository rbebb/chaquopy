import keyword


# The public name is `jclass`, but that would conflict with the JNI typedef of the same name.
# __init__.py performs the renaming.
def jklass(clsname):
    """Returns a proxy class for the given fully-qualified Java class name. The name may use either
    `.` or `/` notation. To refer to a nested or inner class, separate it from the containing
    class with `$`, e.g. `java.lang.Map$Entry`. If the name cannot be resolved, a
    :any:`JavaException` is raised.

    To construct new instances of the class, simply call it like a normal Python class::

        >>> StringBuffer = jclass("java.lang.StringBuffer")
        >>> sb = StringBuffer(1024)

    Methods and fields can be accessed using normal Python syntax::

        >>> String = jclass("java.lang.String")
        >>> sb.append(True).append(123).append(cast(String, None)).append(3.142)
        <java.lang.StringBuffer 'true123null3.142'>
        >>> sb.length()
        16
        >>> System = jclass("java.lang.System")
        >>> sb.toString()
        u'true123null3.142'
        >>> System.out.println(sb)
        true123null3.142

        >>> Point = jclass("java.awt.Point")
        >>> p = Point(3, 4)
        >>> p.x
        3
        >>> p.y
        4
        >>> p.x = 7
        >>> p.getX()
        7.0

    If a method or field name clashes with a Python reserved word, an underscore is appended,
    e.g. `print` becomes `print_`. The original name is still accessible via :any:`getattr`.

    Aside from attribute access, Java proxy objects also support the following Python
    operations:

    * :any:`str` calls `toString
      <https://docs.oracle.com/javase/7/docs/api/java/lang/Object.html#toString()>`_.
    * `==` and `!=` call `equals
      <https://docs.oracle.com/javase/7/docs/api/java/lang/Object.html#equals(java.lang.Object)>`_.
    * :any:`hash` calls `hashCode
      <https://docs.oracle.com/javase/7/docs/api/java/lang/Object.html#hashCode()>`_.

    The Java class hierarchy is not currently reflected in Python, e.g. `issubclass(String,
    Object)` and `isinstance(String("hello"), Object)` will both return `False`. This may change
    in the future.
    """
    clsname = clsname.replace('/', '.')
    if clsname.startswith("L") and clsname.endswith(";"):
        clsname = clsname[1:-1]
    if clsname.startswith('$Proxy'):
        # The Dalvik VM is not able to give us introspection on these (FindClass returns NULL).
        return jklass("java.lang.Object")

    cls = jclass_cache.get(clsname)
    if not cls:
        cls = reflect_class(clsname)
        cache_class(cls)
    return cls


jclass_cache = {}

def cache_class(cls):
    jclass_cache[cls.__name__] = cls


def reflect_class(clsname):
    setup_bootstrap_classes()

    if clsname.startswith("["):
        raise ValueError("Cannot reflect an array type")
    if clsname in java.primitives_by_name:
        raise ValueError("Cannot reflect a primitive type")

    classDict = {"__javaclass__": clsname}
    c = Class(instance=CQPEnv().FindClass(clsname))

    methods = c.getMethods() + c.getConstructors()
    methods_name = [x.getName() for x in methods]
    for index, method in enumerate(methods):
        if method.isSynthetic():
            continue

        name = methods_name[index]
        if name in classDict:
            continue
        if methods_name.count(name) == 1:
            method = JavaMethod.from_method(method)
        else:
            # TODO #5212: this is quadratic. We should sort the original list by name and then
            # use itertools.groupby.
            jms = []
            for index, subname in enumerate(methods_name):
                if subname != name:
                    continue
                method = methods[index]
                if method.isSynthetic():
                    continue
                jms.append(JavaMethod.from_method(method))
            method = JavaMultipleMethod(jms)

        if name == clsname:
            # The constructor's name in java.lang.reflect is the fully-qualified class name,
            # and its name in JNI is "<init>", but neither of those are valid Python
            # identifiers.
            name = "__javaconstructor__"
        classDict[name] = method

    for field in c.getFields():
        # TODO #5183 method and field with same name
        #
        # TODO #5208 depending on the order of getFields(), this may hide the wrong field in
        # case of a parent/child duplicate name.
        if field.getName() in classDict:
            continue
        modifiers = field.getModifiers()
        classDict[field.getName()] = JavaField(field.getDeclaringClass(),
                                               java.jni_sig(field.getType()),
                                               static=Modifier.isStatic(modifiers),
                                               final=Modifier.isFinal(modifiers))

    return JavaClass(clsname, (JavaObject,), classDict)


# This isn't done during module initialization because we don't have a JVM yet, and we don't
# want to automatically start one because we might already be in a Java process.
def setup_bootstrap_classes():
    if "Constructor" in globals():  # Last class to be defined
        return

    # Declare only the members used by reflect_class or anything it calls.
    # Generated with the help of runtime/make_proxy.py
    global Class, Modifier, Method, Field, Constructor

    class Class(six.with_metaclass(JavaClass, JavaObject)):
        __javaclass__ = 'java.lang.Class'
        getConstructors = JavaMethod('()[Ljava/lang/reflect/Constructor;')
        getFields = JavaMethod('()[Ljava/lang/reflect/Field;')
        getMethods = JavaMethod('()[Ljava/lang/reflect/Method;')
        getName = JavaMethod('()Ljava/lang/String;')

    class Modifier(six.with_metaclass(JavaClass, JavaObject)):
        __javaclass__ = 'java.lang.reflect.Modifier'
        __javaconstructor__ = JavaMethod('()V')
        isAbstract = JavaMethod('(I)Z', static=True)
        isFinal = JavaMethod('(I)Z', static=True)
        isStatic = JavaMethod('(I)Z', static=True)

    class Method(six.with_metaclass(JavaClass, JavaObject)):
        __javaclass__ = 'java.lang.reflect.Method'
        getDeclaringClass = JavaMethod('()Ljava/lang/Class;')
        getModifiers = JavaMethod('()I')
        getName = JavaMethod('()Ljava/lang/String;')
        getParameterTypes = JavaMethod('()[Ljava/lang/Class;')
        getReturnType = JavaMethod('()Ljava/lang/Class;')
        isSynthetic = JavaMethod('()Z')
        isVarArgs = JavaMethod('()Z')

    class Field(six.with_metaclass(JavaClass, JavaObject)):
        __javaclass__ = 'java.lang.reflect.Field'
        getDeclaringClass = JavaMethod('()Ljava/lang/Class;')
        getModifiers = JavaMethod('()I')
        getName = JavaMethod('()Ljava/lang/String;')
        getType = JavaMethod('()Ljava/lang/Class;')

    class Constructor(six.with_metaclass(JavaClass, JavaObject)):
        __javaclass__ = 'java.lang.reflect.Constructor'
        getDeclaringClass = JavaMethod('()Ljava/lang/Class;')
        getModifiers = JavaMethod('()I')
        getName = JavaMethod('()Ljava/lang/String;')
        getParameterTypes = JavaMethod('()[Ljava/lang/Class;')
        isSynthetic = JavaMethod('()Z')
        isVarArgs = JavaMethod('()Z')

    # The last class defined should match the check at the top of this function.

    classes = [Class, Modifier, Method, Field, Constructor]
    for cls in classes:
        cache_class(cls)

    # Now fill in all the other members.
    for cls in classes:
        cache_class(reflect_class(cls.__name__))


# cdef'ed metaclasses don't work with six's with_metaclass (https://trac.sagemath.org/ticket/18503)
class JavaClass(type):
    def __new__(metacls, classname, bases, classDict):
        classDict["__javaclass__"] = classname = classDict["__javaclass__"].replace("/", ".")
        classDict["j_cls"] = CQPEnv().FindClass(classname).global_ref()

        # These are defined here rather than in JavaObject because cdef classes are required to
        # use __richcmp__ instead.
        classDict["__eq__"] = lambda self, other: self.equals(other)
        classDict["__ne__"] = lambda self, other: not self.equals(other)

        # TODO #5153 disabled until tested, and should also generate a setter.
        # if name != 'getClass' and bean_getter(name) and len(method.getParameterTypes()) == 0:
        #     classDict[lower_name(name[3:])] = \
        #         (lambda n: property(lambda self: getattr(self, n)()))(name)
        #
        # TODO #5154 disabled until tested, and should also implement other container
        # interfaces.
        # for iclass in c.getInterfaces():
        #     if iclass.getName() == 'java.util.List':
        #         classDict['__getitem__'] = lambda self, index: self.get(index)
        #         classDict['__len__'] = lambda self: self.size()

        # As recommended by PEP 8, append an underscore to member names which are reserved
        # words. (The original name is still accessible via getattr().)
        aliases = [(name + "_", name) for name in classDict if is_reserved_word(name)]
        for alias, name in aliases:
            if alias not in classDict:
                classDict[alias] = classDict[name]

        # classname must be "str" type, whatever that is on this Python version.
        return type.__new__(metacls, str(classname), bases, classDict)

    def __init__(cls, classname, bases, classDict):
        for name, value in six.iteritems(classDict):
            if isinstance(value, JavaMember):
                value.set_resolve_info(cls, str_for_c(name))

    # The default metaclass implementation will never call a descriptor's __set__ with the
    # object as None, but will simply assign to the class dictionary. We override it to allow
    # Java static fields to be set, and to prevent setting anything other than a field.
    def __setattr__(cls, key, value):
        set_attribute(cls, None, key, value)


def lower_name(s):
    return s[:1].lower() + s[1:] if s else ''

def bean_getter(s):
    return (s.startswith('get') and len(s) > 3 and s[3].isupper()) or (s.startswith('is') and len(s) > 2 and s[2].isupper())


# Ensure the same aliases are available on all Python versions
EXTRA_RESERVED_WORDS = {'exec', 'print',                      # Removed in Python 3.0
                        'nonlocal', 'True', 'False', 'None',  # Python 3.0
                        'async', 'await'}                     # Python 3.7

def is_reserved_word(word):
    return keyword.iskeyword(word) or word in EXTRA_RESERVED_WORDS


# TODO #5168 Replicate Java class hierarchy
#
# Avoid adding "def" methods to this class because they may conflict with Java member names.
cdef class JavaObject(object):
    '''Base class for Python -> Java proxy classes'''

    # Member variables declared in .pxd

    def __init__(self, *args, JNIRef instance=None):
        super(JavaObject, self).__init__()
        cdef JNIEnv *env = get_jnienv()
        if instance is not None:
            if not env[0].IsInstanceOf(env, instance.obj, (<JNIRef?>self.j_cls).obj):
                raise TypeError(f"cannot create {self.__javaclass__} proxy from "
                                f"{lookup_java_object_name(env, instance.obj)} instance")
            self.j_self = instance.global_ref()
        else:
            # Java SE 8 raises an InstantiationException when calling NewObject on an abstract
            # class, but Android 6 crashes with a CheckJNI error.
            klass = j2p(env, self.j_cls)
            Modifier = java.jclass("java.lang.reflect.Modifier")
            if Modifier.isAbstract(klass.getModifiers()):
                raise TypeError(f"{self.__javaclass__} is abstract and cannot be instantiated")
            try:
                constructor = self.__javaconstructor__
            except AttributeError:
                raise TypeError(f"{self.__javaclass__} has no accessible constructors")
            self.j_self = constructor(*args)

    # Override to prevent setting anything other than a field.
    def __setattr__(self, key, value):
        set_attribute(type(self), self, key, value)

    def __repr__(self):
        if self.j_self:
            ts = str(self)
            if ts is not None and \
               ts.startswith(self.__javaclass__):  # e.g. "java.lang.Object@28d93b30"
                return f"<{ts}>"
            else:
                return f"<{self.__javaclass__} '{ts}'>"
        else:
            return f"<{self.__javaclass__} (no instance)>"

    def __str__(self):
        return self.toString()

    def __hash__(self):
        return self.hashCode()


def set_attribute(cls, obj, key, value):
    try:
        member = cls.__dict__[key]
    except KeyError:
        subject = f"'{cls.__name__}' object" if obj else f"type object '{cls.__name__}'"
        raise AttributeError(f"{subject} has no attribute '{key}'")
    if not isinstance(member, JavaField):
        raise AttributeError(f"'{cls.__name__}.{key}' is not a field")
    member.__set__(obj, value)


cdef class JavaMember(object):
    cdef jc
    cdef name
    cdef bint is_static

    def __init__(self, bint static=False):
        self.is_static = static

    def classname(self):
        return self.jc.__javaclass__ if self.jc else None

    def set_resolve_info(self, jc, name):
        # jc is the JavaClass of which we are a member, so this will cause a reference cycle.
        self.jc = jc
        self.name = name


cdef class JavaField(JavaMember):
    # On Android 6.0, accessing an inherited static field or interface constant via a subclass
    # causes a CheckJNI error like "static jfieldID 0xaa6529e8 not valid for class", even
    # though GetStaticField had no problem with it. So we use the declaring class instead.
    #
    # This doesn't seem to affect methods or non-static fields.
    cdef JavaObject klass

    cdef jfieldID j_field
    cdef definition
    cdef bint is_final

    def __repr__(self):
        return (f"<JavaField('{self.fqn()}', type='{java.sig_to_java(self.definition)}'"
                f"{', static=True' if self.is_static else ''}"
                f"{', final=True' if self.is_final else ''})>")

    def __init__(self, JavaObject klass, definition, *, static=False, final=False):
        super(JavaField, self).__init__(static)
        self.klass = klass
        self.definition = str_for_c(definition)
        self.is_final = final

    def fqn(self):
        """Returns the fully-qualified name of the field. Not used in any place where the field type
        might also be relevant.
        """
        return f"{self.classname()}.{self.name}"

    cdef jfieldID id(self) except NULL:
        self.ensure_field()
        return self.j_field

    cdef void ensure_field(self) except *:
        if self.j_field != NULL:
            return
        cdef JNIEnv *j_env = get_jnienv()
        if self.name is None:
            raise Exception('Field name has not been set')
        if self.is_static:
            self.j_field = j_env[0].GetStaticFieldID(
                    j_env, self.klass.j_self.obj, self.name, self.definition)
        else:
            self.j_field = j_env[0].GetFieldID(
                    j_env, self.klass.j_self.obj, self.name, self.definition)
        if self.j_field == NULL:
            expect_exception(j_env, f'Get[Static]Field failed for {self}')

    def __get__(self, obj, objtype):
        cdef jobject j_self
        self.ensure_field()
        if self.is_static:
            return self.read_static_field()
        else:
            if obj is None:
                raise AttributeError(f'Cannot access {self.fqn()} in static context')
            j_self = (<JavaObject?>obj).j_self.obj
            return self.read_field(j_self)

    def __set__(self, obj, value):
        cdef jobject j_self
        self.ensure_field()
        if self.is_final:  # 'final' is not enforced by JNI, so we need to do it ourselves.
            raise AttributeError(f"{self.fqn()} is a final field")

        if self.is_static:
            self.write_static_field(value)
        else:
            # obj would never be None with the standard descriptor protocol, but see
            # JavaClass.__setattr__.
            if obj is None:
                raise AttributeError(f'Cannot access {self.fqn()} in static context')
            else:
                j_self = (<JavaObject?>obj).j_self.obj
                self.write_field(j_self, value)

    # Cython auto-generates range checking code for the integral types.
    cdef write_field(self, jobject j_self, value):
        cdef JNIEnv *j_env = get_jnienv()
        j_value = p2j(j_env, self.definition, value)

        r = self.definition[0]
        if r == 'Z':
            j_env[0].SetBooleanField(j_env, j_self, self.j_field, j_value)
        elif r == 'B':
            j_env[0].SetByteField(j_env, j_self, self.j_field, j_value)
        elif r == 'C':
            check_range_char(j_value)
            j_env[0].SetCharField(j_env, j_self, self.j_field, ord(j_value))
        elif r == 'S':
            j_env[0].SetShortField(j_env, j_self, self.j_field, j_value)
        elif r == 'I':
            j_env[0].SetIntField(j_env, j_self, self.j_field, j_value)
        elif r == 'J':
            j_env[0].SetLongField(j_env, j_self, self.j_field, j_value)
        elif r == 'F':
            check_range_float32(j_value)
            j_env[0].SetFloatField(j_env, j_self, self.j_field, j_value)
        elif r == 'D':
            j_env[0].SetDoubleField(j_env, j_self, self.j_field, j_value)
        elif r in 'L[':
            # SetObjectField cannot throw an exception, so p2j must never return an
            # incompatible object.
            j_env[0].SetObjectField(j_env, j_self, self.j_field, (<JNIRef?>j_value).obj)
        else:
            raise Exception(f"Invalid definition for {self.fqn()}: '{self.definition}'")

    cdef read_field(self, jobject j_self):
        cdef JNIEnv *j_env = get_jnienv()
        r = self.definition[0]
        if r == 'Z':
            return bool(j_env[0].GetBooleanField(j_env, j_self, self.j_field))
        elif r == 'B':
            return j_env[0].GetByteField(j_env, j_self, self.j_field)
        elif r == 'C':
            return six.unichr(j_env[0].GetCharField(j_env, j_self, self.j_field))
        elif r == 'S':
            return j_env[0].GetShortField(j_env, j_self, self.j_field)
        elif r == 'I':
            return j_env[0].GetIntField(j_env, j_self, self.j_field)
        elif r == 'J':
            return j_env[0].GetLongField(j_env, j_self, self.j_field)
        elif r == 'F':
            return j_env[0].GetFloatField(j_env, j_self, self.j_field)
        elif r == 'D':
            return j_env[0].GetDoubleField(j_env, j_self, self.j_field)
        elif r in 'L[':
            j_object = LocalRef.adopt(j_env, j_env[0].GetObjectField(j_env, j_self, self.j_field))
            return j2p(j_env, j_object)
        else:
            raise Exception(f"Invalid definition for {self.fqn()}: '{self.definition}'")

    # Cython auto-generates range checking code for the integral types.
    cdef write_static_field(self, value):
        cdef jclass j_class = self.klass.j_self.obj
        cdef JNIEnv *j_env = get_jnienv()
        j_value = p2j(j_env, self.definition, value)

        r = self.definition[0]
        if r == 'Z':
            j_env[0].SetStaticBooleanField(j_env, j_class, self.j_field, j_value)
        elif r == 'B':
            j_env[0].SetStaticByteField(j_env, j_class, self.j_field, j_value)
        elif r == 'C':
            check_range_char(j_value)
            j_env[0].SetStaticCharField(j_env, j_class, self.j_field, ord(j_value))
        elif r == 'S':
            j_env[0].SetStaticShortField(j_env, j_class, self.j_field, j_value)
        elif r == 'I':
            j_env[0].SetStaticIntField(j_env, j_class, self.j_field, j_value)
        elif r == 'J':
            j_env[0].SetStaticLongField(j_env, j_class, self.j_field, j_value)
        elif r == 'F':
            check_range_float32(j_value)
            j_env[0].SetStaticFloatField(j_env, j_class, self.j_field, j_value)
        elif r == 'D':
            j_env[0].SetStaticDoubleField(j_env, j_class, self.j_field, j_value)
        elif r in 'L[':
            # SetStaticObjectField cannot throw an exception, so p2j must never return an
            # incompatible object.
            j_env[0].SetStaticObjectField(j_env, j_class, self.j_field, (<JNIRef?>j_value).obj)
        else:
            raise Exception(f"Invalid definition for {self.fqn()}: '{self.definition}'")

    cdef read_static_field(self):
        cdef jclass j_class = self.klass.j_self.obj
        cdef JNIEnv *j_env = get_jnienv()
        r = self.definition[0]
        if r == 'Z':
            return bool(j_env[0].GetStaticBooleanField(j_env, j_class, self.j_field))
        elif r == 'B':
            return j_env[0].GetStaticByteField(j_env, j_class, self.j_field)
        elif r == 'C':
            return six.unichr(j_env[0].GetStaticCharField(j_env, j_class, self.j_field))
        elif r == 'S':
            return j_env[0].GetStaticShortField(j_env, j_class, self.j_field)
        elif r == 'I':
            return j_env[0].GetStaticIntField(j_env, j_class, self.j_field)
        elif r == 'J':
            return j_env[0].GetStaticLongField(j_env, j_class, self.j_field)
        elif r == 'F':
            return j_env[0].GetStaticFloatField(j_env, j_class, self.j_field)
        elif r == 'D':
            return j_env[0].GetStaticDoubleField(j_env, j_class, self.j_field)
        elif r in 'L[':
            j_object = LocalRef.adopt(j_env, j_env[0].GetStaticObjectField(j_env, j_class,
                                                                           self.j_field))
            return j2p(j_env, j_object)
        else:
            raise Exception(f"Invalid definition for {self.fqn()}: '{self.definition}'")


cdef class JavaMethod(JavaMember):
    cdef jmethodID j_method
    cdef definition
    cdef object definition_return
    cdef object definition_args
    cdef bint is_constructor
    cdef bint is_varargs

    def __repr__(self):
        return (f"<JavaMethod('{self.fqn()}', type='{java.sig_to_java(self.definition_return)}'"
                f"{', static=True' if self.is_static else ''}"
                f"{', varargs=True' if self.is_varargs else ''})>")

    def fqn(self):
        """Returns the fully-qualified name of the method, plus its parameter types. Not used in any
        place where the return type might also be relevant.
        """
        return f"{self.classname()}.{self.name}{self.format_args()}"

    def format_args(self):
        formatted_args = []
        for i, arg in enumerate(self.definition_args):
            if self.is_varargs and i == (len(self.definition_args) - 1):
                formatted_args.append(java.sig_to_java(arg[1:]) + "...")
            else:
                formatted_args.append(java.sig_to_java(arg))
        return "(" + ", ".join(formatted_args) + ")"

    @staticmethod
    def from_method(method):
        if hasattr(method, "getReturnType"):
            return_type = method.getReturnType()
        else:  # Constructor
            return_type = java.jvoid
        return JavaMethod(java.jni_method_sig(return_type, method.getParameterTypes()),
                          static=Modifier.isStatic(method.getModifiers()),
                          varargs=method.isVarArgs())

    def __init__(self, definition, *, static=False, varargs=False):
        super(JavaMethod, self).__init__(static)
        self.definition = str_for_c(definition)
        self.definition_return, self.definition_args = parse_definition(definition)
        self.is_varargs = varargs

    def set_resolve_info(self, jc, name):
        if name == "__javaconstructor__":
            name = "<init>"
        self.is_constructor = (name == "<init>")
        super(JavaMethod, self).set_resolve_info(jc, name)

    cdef jmethodID id(self) except NULL:
        self.ensure_method()
        return self.j_method

    cdef void ensure_method(self) except *:
        if self.j_method != NULL:
            return
        cdef JNIEnv *j_env = get_jnienv()
        if self.name is None:
            raise Exception('Method name has not been set')
        if self.is_static:
            self.j_method = j_env[0].GetStaticMethodID(
                    j_env, (<GlobalRef?>self.jc.j_cls).obj, self.name, self.definition)
        else:
            self.j_method = j_env[0].GetMethodID(
                    j_env, (<GlobalRef?>self.jc.j_cls).obj, self.name, self.definition)
        if self.j_method == NULL:
            expect_exception(j_env, f"Get[Static]Method failed for {self}")

    def __get__(self, obj, objtype):
        self.ensure_method()
        if obj is None and not (self.is_static or self.is_constructor):
            # We don't allow the user to get unbound method objects, because passing the target
            # object as the first parameter wouldn't be compatible with the way we implement
            # overload resolution. (It might be possible to fix this, but it's not worth the
            # effort.)
            raise AttributeError(f'Cannot access {self.fqn()} in static context')
        else:
            return lambda *args: self(obj, *args)

    def __call__(self, obj, *args):
        cdef jvalue *j_args = NULL
        cdef tuple d_args = self.definition_args
        cdef JNIEnv *j_env = get_jnienv()

        if self.is_varargs:
            if len(args) < len(d_args) - 1:
                raise TypeError(f'{self.fqn()} takes at least {len(d_args) - 1} arguments '
                                f'({len(args)} given)')

            if len(args) == len(d_args) and assignable_to_array(d_args[-1], args[-1]):
                # As in Java, passing a single None as the varargs parameter will be
                # interpreted as a null array. To pass an an array of one null, use [None].
                pass  # Non-varargs call.
            else:
                args = args[:len(d_args) - 1] + (args[len(d_args) - 1:],)

        if len(args) != len(d_args):
            raise TypeError(f'{self.fqn()} takes {len(d_args)} arguments ({len(args)} given)')

        p2j_args = [p2j(j_env, argtype, arg)
                    for argtype, arg in six.moves.zip(d_args, args)]
        if len(args):
            j_args = <jvalue*>alloca(sizeof(jvalue) * len(d_args))
            populate_args(j_env, d_args, j_args, p2j_args)

        if self.is_constructor:
            result = self.call_constructor(j_env, j_args)
        elif self.is_static:
            result = self.call_static_method(j_env, j_args)
        else:
            # Should never happen, but worth keeping as an extra defense against a
            # native crash.
            if not isinstance(obj, self.jc):
                raise TypeError(f"Unbound method {self.fqn()} must be called with "
                                f"{self.jc.__name__} instance as first argument (got "
                                f"{type(obj).__name__} instance instead)")
            result =  self.call_method(j_env, obj, j_args)

        copy_output_args(d_args, args, p2j_args)
        return result

    cdef GlobalRef call_constructor(self, JNIEnv *j_env, jvalue *j_args):
        cdef jobject j_self = j_env[0].NewObjectA(j_env, (<GlobalRef?>self.jc.j_cls).obj,
                                                  self.j_method, j_args)
        check_exception(j_env)
        return LocalRef.adopt(j_env, j_self).global_ref()

    cdef call_method(self, JNIEnv *j_env, JavaObject obj, jvalue *j_args):
        # These temporary variables are required because Python objects can't be touched during
        # "with nogil".
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object

        ret = None
        cdef jobject j_self = obj.j_self.obj
        r = self.definition_return[0]
        if r == 'V':
            with nogil:
                j_env[0].CallVoidMethodA(j_env, j_self, self.j_method, j_args)
        elif r == 'Z':
            with nogil:
                j_boolean = j_env[0].CallBooleanMethodA(j_env, j_self, self.j_method, j_args)
            ret = bool(j_boolean)
        elif r == 'B':
            with nogil:
                j_byte = j_env[0].CallByteMethodA(j_env, j_self, self.j_method, j_args)
            ret = j_byte
        elif r == 'C':
            with nogil:
                j_char = j_env[0].CallCharMethodA(j_env, j_self, self.j_method, j_args)
            ret = six.unichr(j_char)
        elif r == 'S':
            with nogil:
                j_short = j_env[0].CallShortMethodA(j_env, j_self, self.j_method, j_args)
            ret = j_short
        elif r == 'I':
            with nogil:
                j_int = j_env[0].CallIntMethodA(j_env, j_self, self.j_method, j_args)
            ret = j_int
        elif r == 'J':
            with nogil:
                j_long = j_env[0].CallLongMethodA(j_env, j_self, self.j_method, j_args)
            ret = j_long
        elif r == 'F':
            with nogil:
                j_float = j_env[0].CallFloatMethodA(j_env, j_self, self.j_method, j_args)
            ret = j_float
        elif r == 'D':
            with nogil:
                j_double = j_env[0].CallDoubleMethodA(j_env, j_self, self.j_method, j_args)
            ret = j_double
        elif r in 'L[':
            with nogil:
                j_object = j_env[0].CallObjectMethodA(j_env, j_self, self.j_method, j_args)
            check_exception(j_env)
            ret = j2p(j_env, LocalRef.adopt(j_env, j_object))
        else:
            raise Exception(f"Invalid definition for {self.fqn()}: '{self.definition_return}'")

        check_exception(j_env)
        return ret

    cdef call_static_method(self, JNIEnv *j_env, jvalue *j_args):
        # These temporary variables are required because Python objects can't be touched during
        # "with nogil".
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object

        ret = None
        cdef jclass j_class = (<GlobalRef?>self.jc.j_cls).obj
        r = self.definition_return[0]
        if r == 'V':
            with nogil:
                j_env[0].CallStaticVoidMethodA(j_env, j_class, self.j_method, j_args)
        elif r == 'Z':
            with nogil:
                j_boolean = j_env[0].CallStaticBooleanMethodA(j_env, j_class, self.j_method, j_args)
            ret = bool(j_boolean)
        elif r == 'B':
            with nogil:
                j_byte = j_env[0].CallStaticByteMethodA(j_env, j_class, self.j_method, j_args)
            ret = j_byte
        elif r == 'C':
            with nogil:
                j_char = j_env[0].CallStaticCharMethodA(j_env, j_class, self.j_method, j_args)
            ret = six.unichr(j_char)
        elif r == 'S':
            with nogil:
                j_short = j_env[0].CallStaticShortMethodA(j_env, j_class, self.j_method, j_args)
            ret = j_short
        elif r == 'I':
            with nogil:
                j_int = j_env[0].CallStaticIntMethodA(j_env, j_class, self.j_method, j_args)
            ret = j_int
        elif r == 'J':
            with nogil:
                j_long = j_env[0].CallStaticLongMethodA(j_env, j_class, self.j_method, j_args)
            ret = j_long
        elif r == 'F':
            with nogil:
                j_float = j_env[0].CallStaticFloatMethodA(j_env, j_class, self.j_method, j_args)
            ret = j_float
        elif r == 'D':
            with nogil:
                j_double = j_env[0].CallStaticDoubleMethodA(j_env, j_class, self.j_method, j_args)
            ret = j_double
        elif r in 'L[':
            with nogil:
                j_object = j_env[0].CallStaticObjectMethodA(j_env, j_class, self.j_method, j_args)
            check_exception(j_env)
            ret = j2p(j_env, LocalRef.adopt(j_env, j_object))
        else:
            raise Exception(f"Invalid definition for {self.fqn()}: '{self.definition_return}'")

        check_exception(j_env)
        return ret


class JavaMultipleMethod(JavaMember):
    def __repr__(self):
        return f"JavaMultipleMethod({self.methods})"

    def fqn(self):
        return f"{self.classname()}.{(<JavaMember?>self).name}"

    def __init__(self, methods):
        super(JavaMultipleMethod, self).__init__()
        self.methods = methods
        self.overload_cache = {}

    def __get__(self, obj, objtype):
        return lambda *args: self(obj, *args)

    def set_resolve_info(self, jc, name):
        if name == "__javaconstructor__":
            name = "<init>"
        super(JavaMultipleMethod, self).set_resolve_info(jc, name)
        for jm in self.methods:
            (<JavaMethod?>jm).set_resolve_info(jc, name)

    def __call__(self, obj, *args):
        args_types = tuple(map(type, args))
        best_overload = self.overload_cache.get(args_types)
        if not best_overload:
            # JLS 15.12.2.2. "Identify Matching Arity Methods Applicable by Subtyping"
            varargs = False
            applicable = self.find_applicable(args, autobox=False, varargs=False)

            # JLS 15.12.2.3. "Identify Matching Arity Methods Applicable by Method Invocation
            # Conversion"
            if not applicable:
                applicable = self.find_applicable(args, autobox=True, varargs=False)

            # JLS 15.12.2.4. "Identify Applicable Variable Arity Methods"
            if not applicable:
                varargs = True
                applicable = self.find_applicable(args, autobox=True, varargs=True)

            if not applicable:
                raise TypeError(self.overload_err(f"cannot be applied to", args, self.methods))

            # JLS 15.12.2.5. "Choosing the Most Specific Method"
            maximal = []
            for jm1 in applicable:
                if not any([better_overload(jm2, jm1, args_types, varargs=varargs)
                            for jm2 in applicable if jm2 is not jm1]):
                    maximal.append(jm1)
            if len(maximal) != 1:
                raise TypeError(self.overload_err(f"is ambiguous for arguments", args,
                                                  maximal if maximal else applicable))
            best_overload = maximal[0]
            self.overload_cache[args_types] = best_overload

        return best_overload.__get__(obj, type(obj))(*args)

    def find_applicable(self, args, *, autobox, varargs):
        result = []
        cdef JavaMethod jm
        for jm in self.methods:
            if not (varargs and not jm.is_varargs) and \
               is_applicable(jm.definition_args, args, autobox, varargs):
                result.append(jm)
        return result

    def overload_err(self, msg, args, methods):
        args_type_names = "({})".format(", ".join([type(a).__name__ for a in args]))
        return (f"{self.fqn()} {msg} {args_type_names}: options are " +
                ", ".join([jm.format_args() for jm in methods]))
