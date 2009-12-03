import sys, os, subprocess, logging
from theano.gof.cmodule import (std_libs, std_lib_dirs, std_include_dirs, dlimport,
    get_lib_extension)
import theano.config as config

_logger=logging.getLogger("theano_cuda_ndarray.nvcc_compiler")
_logger.setLevel(logging.WARN)

def error(*args):
    #sys.stderr.write('ERROR:'+ ' '.join(str(a) for a in args)+'\n')
    _logger.error("ERROR: "+' '.join(str(a) for a in args))
def warning(*args):
    #sys.stderr.write('WARNING:'+ ' '.join(str(a) for a in args)+'\n')
    _logger.warning("WARNING: "+' '.join(str(a) for a in args))
def info(*args):
    #sys.stderr.write('INFO:'+ ' '.join(str(a) for a in args)+'\n')
    _logger.info("INFO: "+' '.join(str(a) for a in args))
def debug(*args):
    #sys.stderr.write('DEBUG:'+ ' '.join(str(a) for a in args)+'\n')
    _logger.debug("DEBUG: "+' '.join(str(a) for a in args))

def nvcc_module_compile_str(module_name, src_code, location=None, include_dirs=[], lib_dirs=[], libs=[],
        preargs=[]):
    """
    :param module_name: string (this has been embedded in the src_code
    :param src_code: a complete c or c++ source listing for the module
    :param location: a pre-existing filesystem directory where the cpp file and .so will be written
    :param include_dirs: a list of include directory names (each gets prefixed with -I)
    :param lib_dirs: a list of library search path directory names (each gets prefixed with -L)
    :param libs: a list of libraries to link with (each gets prefixed with -l)
    :param preargs: a list of extra compiler arguments

    :returns: dynamically-imported python module of the compiled code.
    """
    if preargs is None:
        preargs= []
    else: preargs = list(preargs)
    preargs.append('-fPIC')
    no_opt = False
    cuda_root = config.CUDA_ROOT
    include_dirs = std_include_dirs() + include_dirs
    libs = std_libs() + ['cudart'] + libs
    lib_dirs = std_lib_dirs() + lib_dirs
    if cuda_root:
        lib_dirs.append(os.path.join(cuda_root, 'lib'))

    cppfilename = os.path.join(location, 'mod.cu')
    cppfile = file(cppfilename, 'w')

    debug('Writing module C++ code to', cppfilename)
    ofiles = []
    rval = None

    cppfile.write(src_code)
    cppfile.close()
    lib_filename = os.path.join(location, '%s.%s' %
            (module_name, get_lib_extension()))

    debug('Generating shared lib', lib_filename)
    # TODO: Why do these args cause failure on gtx285 that has 1.3 compute capability? '--gpu-architecture=compute_13', '--gpu-code=compute_13', 
    cmd = ['nvcc', '-shared', '-g'] + [pa for pa in preargs if pa.startswith('-O')]
    cmd.extend(['-Xcompiler', ','.join(pa for pa in preargs if not pa.startswith('-O'))])
    cmd.extend('-I%s'%idir for idir in include_dirs)
    cmd.extend(['-o',lib_filename]) 
    cmd.append(cppfilename)
    cmd.extend(['-L%s'%ldir for ldir in lib_dirs])
    cmd.extend(['-l%s'%l for l in libs])
    debug('Running cmd', ' '.join(cmd))

    p = subprocess.Popen(cmd, stderr=subprocess.PIPE)
    stderr = p.communicate()[1] 

    if p.returncode: 
        # filter the output from the compiler
        for l in stderr.split('\n'):
            if not l:
                continue
            # filter out the annoying declaration warnings

            try:
                if l[l.index(':'):].startswith(': warning: variable'):
                    continue
                if l[l.index(':'):].startswith(': warning: label'):
                    continue
            except: 
                pass
            print l
        print '==============================='
        for i, l in enumerate(src_code.split('\n')):
            print i+1, l
        raise Exception('nvcc return status', p.returncode, 'for file',cppfilename)

    #touch the __init__ file
    file(os.path.join(location, "__init__.py"),'w').close()      
    return dlimport(lib_filename)
