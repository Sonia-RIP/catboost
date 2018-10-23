import marshal
import sys
from _codecs import utf_8_decode, utf_8_encode
from _frozen_importlib import _new_module, BuiltinImporter
from _frozen_importlib_external import _os, _path_isfile, path_sep
from _io import FileIO

import __res as __resource

env_entry_point = b'Y_PYTHON_ENTRY_POINT'
env_source_root = b'Y_PYTHON_SOURCE_ROOT'
executable = sys.executable
path_sep = utf_8_encode(path_sep)[0]
sys.modules['run_import_hook'] = __resource

# This is the prefix in contrib/tools/python3/src/Lib/ya.make.
py_prefix = b'py/'
py_prefix_len = len(py_prefix)

Y_PYTHON_SOURCE_ROOT = _os.environ.get(env_source_root)


def _print(*xs):
    """
    This is helpful for debugging, since automatic bytes to str conversion is
    not available yet.  It is also possible to debug with GDB by breaking on
    __Pyx_AddTraceback (with Python GDB pretty printers enabled).
    """
    parts = []
    for s in xs:
        if isinstance(s, bytes):
            s = utf_8_decode(s)[0]
        if not isinstance(s, str):
            s = str(s)
        parts.append(s)
    sys.stderr.write(' '.join(parts) + '\n')


def file_bytes(path):
    # 'open' is not avaiable yet.
    with FileIO(path, 'r') as f:
        return f.read()


def iter_keys(prefix):
    l = len(prefix)
    for idx in range(__resource.count()):
        key = __resource.key_by_index(idx)
        if key.startswith(prefix):
            yield key, key[l:]


def resfs_src(key, resfs_file=False):
    """
    Return the root-relative file path of a resource key.
    """
    if resfs_file:
        key = b'resfs/file/' + key
    return __resource.find(b'resfs/src/' + key)


def _relpath(key):
    """
    Return the root relative path of a virtual path.
    """
    return resfs_src(key, resfs_file=True)


def resfs_resolve(path):
    """
    Return the absolute path of a root relative path if it exists.
    """
    if Y_PYTHON_SOURCE_ROOT:
        abspath = path_sep.join((Y_PYTHON_SOURCE_ROOT, path))
        if _path_isfile(abspath):
            return abspath


def resfs_read(path, builtin=None):
    """
    Return the bytes of the resouce file at the virtual path. (Or None unless it exists.)
    If builtin is True, do not look for it on the filesystem.
    If builtin is False, do not look in the builtin resources.
    """
    if builtin is not True:
        abspath = resfs_resolve(_relpath(path))
        if abspath:
            return file_bytes(abspath)

    if builtin is not False:
        return __resource.find(b'resfs/file/' + path)


def mod_path(mod):
    """
    Return the virtual path to the source code of the module with the given name.
    """
    return py_prefix + utf_8_encode(mod.replace('.', '/') + '.py')[0]


def iter_py_modules(with_keys=False):
    for key, path in iter_keys(b'resfs/file/' + py_prefix):
        if path.endswith(b'.py'):  # It may also end with '.pyc'.
            mod = utf_8_decode(path[:-3].replace(b'/', b'.'))[0]
            if with_keys:
                yield key, mod
            else:
                yield mod


def iter_prefixes(s):
    i = s.find('.')
    while i >= 0:
        yield s[:i]
        i = s.find('.', i + 1)


def resfs_files():
    """
    List builtin resource file paths.
    """
    return [path for _, path in iter_keys(b'resfs/file/')]

class ResourceImporter(object):

    """ A meta_path importer that loads code from built-in resources.
    """

    def __init__(self):
        self.memory = set(iter_py_modules())  # Set of importable module names.
        self.source_map = {}                  # Map from file names to module names.
        self._source_name = {}                # Map from original to altered module names.

        for p in list(self.memory) + list(sys.builtin_module_names):
            for pp in iter_prefixes(p):
                k = pp + '.__init__'
                if k not in self.memory:
                    self.memory.add(k)

    # PEP-302 finder.
    def find_module(self, fullname, path=None):
        try:
            self.is_package(fullname)
        except ImportError:
            return None
        return self

    # PEP-302 extension 1 of 3: data loader.
    def get_data(self, path):
        data = resfs_read(path)
        if data is None:
            raise IOError
        return data

    # PEP-302 extension 2 of 3: get __file__ without importing.
    def get_filename(self, fullname):
        modname = fullname
        if self.is_package(fullname):
            fullname += '.__init__'
        relpath = _relpath(mod_path(fullname))
        if isinstance(relpath, bytes):
            relpath = utf_8_decode(relpath)[0]
        return relpath

    # PEP-302 extension 3 of 3: packaging introspection.
    # Used by `linecache` (while printing tracebacks) unless module filename
    # exists on the filesystem.
    def get_source(self, fullname):
        original_name = self._source_name.get(fullname) or fullname
        if self.is_package(original_name):
            original_name += '.__init__'

        relpath = self.get_filename(original_name)
        if relpath:
            abspath = resfs_resolve(relpath)
            if abspath:
                return utf_8_decode(file_bytes(abspath))[0]
        return utf_8_decode(resfs_read(mod_path(fullname)))[0]

    def get_code(self, fullname):
        modname = fullname
        if self.is_package(fullname):
            fullname += '.__init__'

        path = mod_path(fullname)
        relpath = _relpath(path)
        abspath = resfs_resolve(relpath)
        if abspath:
            data = resfs_read(path, builtin=False)
            return compile(data, abspath, 'exec', dont_inherit=True)

        yapyc_path = path + b'.yapyc3'
        yapyc_data = resfs_read(yapyc_path, builtin=True)
        if yapyc_data:
            return marshal.loads(yapyc_data)
        else:
            py_data = resfs_read(path, builtin=True)
            if py_data:
                return compile(py_data, relpath, 'exec', dont_inherit=True)
            else:
                # This covers packages with no __init__.py in resources.
                return compile('', modname, 'exec', dont_inherit=True)

    def is_package(self, fullname):
        if fullname in self.memory:
            return False

        if fullname + '.__init__' in self.memory:
            return True

        raise ImportError

    # Extension for contrib/python/coverage.
    def file_source(self, filename):
        """
        Return the key of the module source by its resource path.
        """
        if not self.source_map:
            for key, mod in iter_py_modules(with_keys=True):
                path = self.get_filename(mod)
                self.source_map[path] = key

        return self.source_map.get(filename, '')

    # PEP-302 loader.
    def load_module(self, mod_name, fix_name=None):
        code = self.get_code(mod_name)
        is_package = self.is_package(mod_name)
        source_name = self._source_name

        mod = _new_module(mod_name)
        mod.__loader__ = self
        mod.__file__ = code.co_filename

        if is_package:
            mod.__path__ = [executable]
            mod.__package__ = mod_name
        else:
            mod.__package__ = mod_name.rpartition('.')[0]

        sys.modules[mod_name] = mod

        if fix_name:
            mod.__name__ = fix_name
            self._source_name = dict(source_name, **{fix_name: mod_name})

        exec code in mod.__dict__

        if fix_name:
            mod.__name__ = mod_name
            self._source_name = source_name

        # Some hacky modules (e.g. pygments.lexers) replace themselves in
        # `sys.modules` with proxies.
        return sys.modules[mod_name]


class BuiltinSubmoduleImporter(BuiltinImporter):
    @classmethod
    def find_spec(cls, fullname, path=None, target=None):
        if path is not None:
            return super().find_spec(fullname, None, target)
        else:
            return None
            

sys.meta_path.insert(0, BuiltinSubmoduleImporter)

importer = ResourceImporter()
sys.meta_path.insert(0, importer)


def executable_path_hook(path):
    if path == executable:
        return importer

    raise ImportError


sys.path.insert(0, executable)
sys.path_hooks.insert(0, executable_path_hook)

# Indicator that modules and resources are built-in rather than on the file system.
sys.is_standalone_binary = True
sys.frozen = True

# Set of names of importable modules.
sys.extra_modules = importer.memory
