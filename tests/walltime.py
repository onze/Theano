import sys, time
from theano.compile.sandbox.sharedvalue import shared
from theano.compile.sandbox.pfunc import pfunc
from theano import tensor

import numpy

import theano_cuda_ndarray as tcn
from theano_cuda_ndarray.basic_ops import host_from_gpu, gpu_from_host

def compare_fns(fns, input, reps=10):
    times = {}
    for implname, impl in fns.iteritems():
        try:
            print 'TOPOSORT', implname
            for i, n in enumerate(impl.maker.env.toposort()):
                print i, n
        except:
            pass
        t0 = time.time()
        for i in xrange(reps):
            impl(input)
        dt = time.time() - t0
        times[implname] = dt
    return times

def showtimes(times):
    for impl, dt in times.iteritems():
        print impl, dt

def cmp_sigmoids(shape):
    def numpy_sigmoid(input):
        rval = 1.0 / (1.0 + numpy.exp(-input))
    sinput = tensor.Tensor(dtype='float32', broadcastable=(0,)*len(shape))()
    shared_input = tcn.shared_constructor(numpy.random.rand(*shape), 'shared_input')
    times = compare_fns(
            dict( numpy=numpy_sigmoid
                , theano_cpu=pfunc([sinput], 1.0 / (1.0 + tensor.exp(-sinput)))
                , theano_gpu_onboard=pfunc([sinput], [], updates=[(shared_input, 1.0 / (1.0 + tensor.exp(-shared_input)))])
                ),
            input=shared_input.value)
    showtimes(times)
def cmp_sigmoids_T(shape):
    def numpy_sigmoid(input):
        rval = 1.0 / (1.0 + numpy.exp(-input.T))
    sinput = tensor.Tensor(dtype='float32', broadcastable=(0,)*len(shape))()
    shared_input = tcn.shared_constructor(numpy.random.rand(*shape), 'shared_input')
    times = compare_fns(
            dict( numpy=numpy_sigmoid
                , theano_cpu=pfunc([sinput], 1.0 / (1.0 + tensor.exp(-sinput.T)))
                , theano_gpu_onboard=pfunc([sinput], [], updates=[(shared_input, 1.0 / (1.0 +
                    tensor.exp(-shared_input.T)))])
                ),
            input=shared_input.value)
    showtimes(times)

if __name__ == '__main__':
    eval(sys.argv[1])
    #cmp_sigmoids((640, 64*64)) # looks great in profiler
    #cmp_sigmoids((173, 74*49))
    #cmp_sigmoids_T((173, 74*49))
