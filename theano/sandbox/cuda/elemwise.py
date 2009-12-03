import StringIO, sys
import numpy
from theano import Op, Type, Apply, Variable, Constant
from theano import tensor, scalar

import logging, copy
_logger_name = 'theano_cuda_ndarray.elemwise'
_logger = logging.getLogger(_logger_name)
_logger.setLevel(logging.INFO)
_logger.addHandler(logging.StreamHandler()) #TO REMOVE
def warning(*msg):
    _logger.warning(_logger_name+'WARNING: '+' '.join(str(m) for m in msg))
def info(*msg):
    _logger.info(_logger_name+'INFO: '+' '.join(str(m) for m in msg))
def debug(*msg):
    _logger.debug(_logger_name+'DEBUG: '+' '.join(str(m) for m in msg))


def _logical_scalar(x):
    return numpy.all(x.type.broadcastable)

def get_str_list_logical_scalar(node, value_str='ii_i%i_value', data_str='ii_i%i_data[0]'):
    l=[]
    for ipos, i in enumerate(node.inputs):
        if _logical_scalar(i):
            l+=[value_str%ipos]
        else: l+=[data_str%ipos]
    return l
        
class RecAlgo(object):
    def c_src_kernel(self, node, nodename):
        nd = node.outputs[0].type.ndim
        sio = StringIO.StringIO()
        #print 'C_SRC_KERNEL', sio.getvalue()


        for ipos, i in enumerate(node.inputs):
            print >> sio, "//    Input  ", ipos, str(i.type)
        for ipos, i in enumerate(node.outputs):
            print >> sio, "//    Output ", ipos, str(i.type)
        print >> sio, "static __global__ void kernel_%s_%s(unsigned int numEls" %(self.scalar_op.__class__.__name__,nodename)
        if (nd):
            print >> sio, "\t,", ", ".join("unsigned int log2_dim%i" % i for i in xrange(nd))
        #declare inputs
        for ipos, i in enumerate(node.inputs):
            s = ", ".join(["const float * i%i_data" % ipos] + list("int i%i_str_%i" % (ipos, d) for d in xrange(nd)))
            print >> sio, "\t,", s
        #declare outputs
        for ipos, i in enumerate(node.outputs):
            s = ", ".join(["float * o%i_data" % ipos] + list("int o%i_str_%i" % (ipos, d) for d in xrange(nd)))
            print >> sio, "\t,", s
            #print >> sio, "\t,", ", ".join("int o%i_str_%i" % (ipos, d) for d in xrange(nd))
            #print >> sio, "\t,", "float * o%i_data" % ipos
        print >> sio, "\t)\n{"
        print >> sio, "    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;"
        print >> sio, "    const unsigned int numThreads = blockDim.x * gridDim.x;"

        # For each input that is a scalar which has been broadcasted to a tensor,
        #     load it into a local variable
        for ipos, i in enumerate(node.inputs):
            if _logical_scalar(i):
                print >> sio, "    const float ii_i%i_value = i%i_data[0];" % (ipos, ipos)

        
        #TODO: insert code to check for strides of 1, and use a different loop
        
        #loop over the elements to be treated by this kernel call
        print >> sio, "    for (unsigned int i = idx; i < numEls; i += numThreads) {"
        # calculate the data pointers for all arguments
        print >> sio, "        unsigned int ii = i;"
        for ipos, i in enumerate(node.inputs):
            if not _logical_scalar(i):
                print >> sio, "        const float * ii_i%i_data = i%i_data;" % (ipos, ipos)
        for ipos, i in enumerate(node.outputs):
            print >> sio, "        float * ii_o%i_data = o%i_data;" % (ipos, ipos)
        for d in xrange(nd-1, -1, -1):
            if d > 0:
                print >> sio, "        unsigned int pos%i = INTMOD_POW2(ii, log2_dim%i);" %(d, d)
                print >> sio, "        ii = INTDIV_POW2(ii, log2_dim%i);" %d
            else:
                print >> sio, "        unsigned int pos%i = ii;" %d
            for ipos, i in enumerate(node.inputs):
                if not _logical_scalar(i):
                    print >> sio, "        ii_i%i_data += pos%i * i%i_str_%i;" % (ipos, d, ipos, d)
            for ipos, i in enumerate(node.outputs):
                print >> sio, "        ii_o%i_data += pos%i * o%i_str_%i;" % (ipos, d, ipos, d)

        # perform the scalar operation on the input and output references
        #TODO: What if the scalar_op needs support_code??
        task_code = self.scalar_op.c_code(
                Apply(self.scalar_op,
                    [scalar.Scalar(dtype = input.type.dtype)() for input in node.inputs],
                    [scalar.Scalar(dtype = output.type.dtype)() for output in node.outputs])
                , nodename + '_scalar_'
                , get_str_list_logical_scalar(node)
                , ['ii_o%i_data[0]'%ipos for ipos, i in enumerate(node.outputs)] 
                , sub=dict(fail='return;')) #TODO: set a failure code somehow!!!
        print >> sio, "       ", task_code
        print >> sio, "    }"

        #TODO: insert runtime stride checks that select the best loop order either here, or in
        # the host code that launched the  kernel (host code probably better spot)

        #indent = " "*(4*d+7)
        #for ipos, i in enumerate(node.inputs):
            #print >> sio, indent, "const float * i%i" % ipos, '= i%i_data', ''
        print >> sio, "}"

        #print sio.getvalue()
        return sio.getvalue()

    def c_src_callkernel(self, node, nodename):
        nd = node.outputs[0].type.ndim
        d = dict()
        #input_params and output_params go into the function declaration/definition
        input_params = ", ".join("const float * i%i_data, const int * i%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.inputs)))
        output_params = ", ".join("float * o%i_data, const int * o%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.outputs)))

        #input_args and output_args go into the recursive call.
        input_args = ", ".join("i%i_data, i%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.inputs)))
        output_args = ", ".join("o%i_data, o%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.outputs)))

        # kernel_call_args are used to invoke the cuda kernel
        kernel_call_args = ["numEls"]
        kernel_call_args.extend("log2_dims[%i]"%di for di in xrange(nd))
        for ipos in xrange(len(node.inputs)):
            kernel_call_args.append(
                    ", ".join(["i%i_data"%ipos] + list("i%i_str[%i]"%(ipos, di) for di in xrange(nd)))
                    )
            #strides = ", ".join("i%i_str[%i]"%(ipos, di) for di in xrange(nd))
            #kernel_call_args.append( "%s, i%i_data" % (strides, ipos))
        for ipos in xrange(len(node.outputs)):
            kernel_call_args.append(
                    ", ".join(["o%i_data"%ipos] + list("o%i_str[%i]"%(ipos, di) for di in xrange(nd)))
                    )
            #strides = ", ".join("o%i_str[%i]"%(ipos, di) for di in xrange(nd))
            #kernel_call_args.append( "%s, o%i_data" % (strides, ipos))
        kernel_call_args = ", ".join(kernel_call_args)

        # the data_pointer_increments are inserted after each recursive call
        data_ptr_inc = []
        for ipos in xrange(len(node.inputs)):
            data_ptr_inc.append("i%i_data += (1<< log2_dim) * i%i_str[d]" %(ipos, ipos))
        for ipos in xrange(len(node.outputs)):
            data_ptr_inc.append("o%i_data += (1<< log2_dim) * o%i_str[d]" %(ipos, ipos))
        data_ptr_inc = ";\n".join(data_ptr_inc)


        d.update(locals())
        d["scalar_op"]=self.scalar_op.__class__.__name__
        return """

        static void callkernel_%(nodename)s(const unsigned int numEls, const int d,
            const int * dims, int * log2_dims,
            %(input_params)s,
            %(output_params)s)
        {
            if (d == %(nd)s)
            {
                int threads_per_block = std::min(numEls, (unsigned int)NUM_VECTOR_OP_THREADS_PER_BLOCK);
                //a ceil would be better here
                int n_blocks = std::min(numEls/threads_per_block + (numEls %% threads_per_block?1:0), (unsigned int)NUM_VECTOR_OP_BLOCKS);
                kernel_%(scalar_op)s_%(nodename)s<<<n_blocks, threads_per_block>>>(%(kernel_call_args)s);
                //std::cerr << "ADDCALL a str" << i0_str[0] << " "<< i0_str[1] << "\\n";
                //std::cerr << "ADDCALL a data" << i0_data << "\\n";
                //std::cerr << "ADDCALL b str" << i1_str[0] << " "<< i1_str[1] << "\\n";
                //std::cerr << "ADDCALL b data" << i1_data << "\\n";
                //std::cerr << "ADDCALL z str" << o0_str[0] << " "<< o0_str[1] << "\\n";
                //std::cerr << "ADDCALL z data" << o0_data << "\\n";
            }
            else
            {
                //std::cerr << "_ADDCALL d " << d << "\\n";
                unsigned int dim_d = dims[d];
                //std::cerr << "_ADDCALL dim_d " << dim_d << "\\n";
                int log2_dim = 0;
                while(dim_d)
                {
                        //std::cerr << "___ADDCALL d " << d << " " << dim_d << "\\n";
                        if (dim_d&1)
                        {
                            log2_dims[d] = log2_dim; 
                            //std::cerr << "___ADDCALL a str" << i0_str[0] << " "<< i0_str[1] << "\\n";
                            //std::cerr << "___ADDCALL a data" << i0_data << "\\n";
                        //std::cerr << "___ADDCALL b str" << i1_str[0] << " "<< i1_str[1] << "\\n";
                        //std::cerr << "___ADDCALL b data" << i1_data << "\\n";
                        //std::cerr << "___ADDCALL z str" << o0_str[0] << " "<< o0_str[1] << "\\n";
                        //std::cerr << "___ADDCALL z data" << o0_data << "\\n";
                        callkernel_%(nodename)s(numEls * (1<<log2_dim), d+1, dims, log2_dims, 
                            %(input_args)s,
                            %(output_args)s);

                        %(data_ptr_inc)s;
                        //i0_data += (1 << log2_dim) * i0_str[d];
                        //i1_data += (1 << log2_dim) * i1_str[d];
                        //o0_data += (1 << log2_dim) * o0_str[d];
                    }
                    log2_dim += 1;
                    dim_d >>= 1;
                }
            }
        }
        """ %d

    def c_support_code_apply(self, node, nodename):
        return self.c_src_kernel(node, nodename) + self.c_src_callkernel(node, nodename)

class NaiveAlgo(object):
    verbose = 0 # 1 or 2 for more verbose output.
    cache_version = ()
    cache_version = ('debug', 6, verbose)

    def __init__(self, scalar_op):
        self.scalar_op = scalar_op

    def c_src_kernel(self, node, nodename, nd):
        sio = StringIO.StringIO()
        #print 'C_SRC_KERNEL', sio.getvalue()

        for ipos, i in enumerate(node.inputs):
            print >> sio, "//    Input  ", ipos, str(i.type)
        for ipos, i in enumerate(node.outputs):
            print >> sio, "//    Output ", ipos, str(i.type)
        print >> sio, "static __global__ void kernel_%s_%s_%s_%s(unsigned int numEls" %(self.scalar_op.__class__.__name__,nodename, id(self), nd)
        if (nd):
            print >> sio, "\t,", ", ".join("const int dim%i" % i for i in xrange(nd))
        #declare inputs
        for ipos, i in enumerate(node.inputs):
            s = ", ".join(["const float * i%i_data" % ipos] + list("int i%i_str_%i" % (ipos, d) for d in xrange(nd)))
            print >> sio, "\t,", s
        #declare outputs
        for ipos, i in enumerate(node.outputs):
            s = ", ".join(["float * o%i_data" % ipos] + list("int o%i_str_%i" % (ipos, d) for d in xrange(nd)))
            print >> sio, "\t,", s
            #print >> sio, "\t,", ", ".join("int o%i_str_%i" % (ipos, d) for d in xrange(nd))
            #print >> sio, "\t,", "float * o%i_data" % ipos
        print >> sio, "\t)\n{"
        print >> sio, "    const int idx = blockIdx.x * blockDim.x + threadIdx.x;"
        print >> sio, "    const int numThreads = blockDim.x * gridDim.x;"

        # For each input that is a scalar which has been broadcasted to a tensor,
        #     load it into a local variable
        for ipos, i in enumerate(node.inputs):
            if _logical_scalar(i):
                print >> sio, "    const float ii_i%i_value = i%i_data[0];" % (ipos, ipos)

        
        #TODO: insert code to check for strides of 1, and use a different loop
        
        #loop over the elements to be treated by this kernel call
        print >> sio, "    for (int i = idx; i < numEls; i += numThreads) {"
        # calculate the data pointers for all arguments
        print >> sio, "        int ii = i;"
        for ipos, i in enumerate(node.inputs):
            if not _logical_scalar(i):
                print >> sio, "        const float * ii_i%i_data = i%i_data;" % (ipos, ipos)
        for ipos, i in enumerate(node.outputs):
            print >> sio, "        float * ii_o%i_data = o%i_data;" % (ipos, ipos)
        for d in xrange(nd-1, -1, -1):
            if d > 0:
                print >> sio, "        int pos%i = ii %% dim%i;" %(d, d)
                print >> sio, "        ii = ii / dim%i;" %d
            else:
                print >> sio, "        int pos%i = ii;" %d

            for ipos, i in enumerate(node.inputs):
                if not _logical_scalar(i):
                    print >> sio, "        ii_i%i_data += pos%i * i%i_str_%i;" % (ipos, d, ipos, d)
            for ipos, i in enumerate(node.outputs):
                print >> sio, "        ii_o%i_data += pos%i * o%i_str_%i;" % (ipos, d, ipos, d)

        # perform the scalar operation on the input and output references
        #TODO: What if the scalar_op needs support_code??
        task_code = self.scalar_op.c_code(
                Apply(self.scalar_op,
                    [scalar.Scalar(dtype = input.type.dtype)() for input in node.inputs],
                    [scalar.Scalar(dtype = output.type.dtype)() for output in node.outputs])
                , nodename + '_scalar_'
                , get_str_list_logical_scalar(node)
                , ['ii_o%i_data[0]'%ipos for ipos, i in enumerate(node.outputs)] 
                , sub=dict(fail='return;')) #TODO: set a failure code somehow!!!
        print >> sio, "       ", task_code
        print >> sio, "    }"

        #TODO: insert runtime stride checks that select the best loop order either here, or in
        # the host code that launched the  kernel (host code probably better spot)

        #indent = " "*(4*d+7)
        #for ipos, i in enumerate(node.inputs):
            #print >> sio, indent, "const float * i%i" % ipos, '= i%i_data', ''
        print >> sio, "}"

        #print sio.getvalue()
        return sio.getvalue()

    def c_src_kernel_tiling(self, node, nodename):
        """ The kernel applies to problems with <= 5 dimensions """

        #The kernel is intended to be structured roughly like this:
        """
        static __global__ void kernel()
        {
            for (int v = blockIdx.y; v < dim0; v += gridDim.x)
            {
                for (int w = blockIdx.y; w < dim1; w += gridDim.y)
                {
                    for (int x = threadIdx.x; x < dim2; x += blockDim.x)
                    {
                        for (int y = threadIdx.y; y < dim3; y += blockDim.y)
                        {
                            for (int z = threadIdx.z; z < dim4; z += blockDim.z)
                            {
                                out[v * out_stride[0] + ...] = f(in1[...],  in2[...])
                            }
                        }
                    }
                }
            }
        }

        """

        nd = node.outputs[0].type.ndim
        sio = StringIO.StringIO()
        #print 'C_SRC_KERNEL', sio.getvalue()

        if nd in (4,):
            # print some leading comments to make the code easier to read
            for ipos, i in enumerate(node.inputs):
                print >> sio, "//    Input  ", ipos, str(i.type)
            for ipos, i in enumerate(node.outputs):
                print >> sio, "//    Output ", ipos, str(i.type)
            print >> sio, "static __global__ void kernel_%s_%s_%s_%s(unsigned int numEls" %(
                    self.scalar_op.__class__.__name__,
                    nodename, 
                    id(self),
                    'tiling%i'%nd)
            if (nd):
                print >> sio, "\t,", ", ".join("const int dim%i" % i for i in xrange(nd))
            #declare inputs
            for ipos, i in enumerate(node.inputs):
                s = ", ".join(["const float * i%i_data" % ipos] + list("int i%i_str_%i" % (ipos, d) for d in xrange(nd)))
                print >> sio, "\t,", s
            #declare outputs
            for ipos, i in enumerate(node.outputs):
                s = ", ".join(["float * o%i_data" % ipos] + list("int o%i_str_%i" % (ipos, d) for d in xrange(nd)))
                print >> sio, "\t,", s
                #print >> sio, "\t,", ", ".join("int o%i_str_%i" % (ipos, d) for d in xrange(nd))
                #print >> sio, "\t,", "float * o%i_data" % ipos
            print >> sio, "\t)\n{"

            # For each input that is a scalar which has been broadcasted to a tensor,
            #     load it into a local variable
            print >> sio, "    __shared__ float value0[%i];" % len(node.inputs)
            print >> sio, "    __shared__ int shared_dims[%(nd)s];" % locals()
            #print >> sio, "    __shared__ int shared_i_str[%(n_in)s][%(nd)s]"
            print >> sio, "    if ((threadIdx.x == 0) && (threadIdx.y == 0)) {"
            for ipos, i in enumerate(node.inputs):
                if _logical_scalar(i):
                    print >> sio, "    value0[%i] = i%i_data[0];" % (ipos, ipos)
            for ipos in xrange(nd):
                print >> sio, "    shared_dims[%i] = dim%i;" % (ipos, ipos)
            print >> sio, "    }"
            print >> sio, "    __syncthreads();"
        

            if (nd == 4):
                print >> sio, """
                for (int pos0 = blockIdx.x; pos0 < shared_dims[0]; pos0 += gridDim.x)
                {
                    for (int pos1 = blockIdx.y; pos1 < shared_dims[1]; pos1 += gridDim.y)
                    {
                        //for (int pos2 = threadIdx.x; pos2 < shared_dims[2]; pos2 += blockDim.x)
                        for (int pos2 = threadIdx.y; pos2 < shared_dims[2]; pos2 += blockDim.y)
                        {
                            //for (int pos3 = threadIdx.y; pos3 < shared_dims[3]; pos3 += blockDim.y)
                            for (int pos3 = threadIdx.x; pos3 < shared_dims[3]; pos3 += blockDim.x)
                            {
                """
            else:
                raise NotImplementedError()
            
            for ipos, i in enumerate(node.inputs):
                if not _logical_scalar(i):
                    print >> sio, "        const float * ii_i%i_data = i%i_data;" % (ipos, ipos)
            for ipos, i in enumerate(node.outputs):
                print >> sio, "        float * ii_o%i_data = o%i_data;" % (ipos, ipos)
            for d in xrange(nd):
                for ipos, i in enumerate(node.inputs):
                    if not _logical_scalar(i):
                        print >> sio, "        ii_i%i_data += pos%i * i%i_str_%i;" % (ipos, d, ipos, d)
                for ipos, i in enumerate(node.outputs):
                    print >> sio, "        ii_o%i_data += pos%i * o%i_str_%i;" % (ipos, d, ipos, d)

            # perform the scalar operation on the input and output references
            #TODO: What if the scalar_op needs support_code??
            task_code = self.scalar_op.c_code(
                    Apply(self.scalar_op,
                        [scalar.Scalar(dtype = input.type.dtype)() for input in node.inputs],
                        [scalar.Scalar(dtype = output.type.dtype)() for output in node.outputs])
                    , nodename + '_scalar_'
                    , get_str_list_logical_scalar(node, value_str='value0[%i]')
                    , ['ii_o%i_data[0]'%ipos for ipos, i in enumerate(node.outputs)] 
                    , sub=dict(fail='return;')) #TODO: set a failure code somehow!!!
            print >> sio, "       ", task_code

            print >> sio, "    }" * nd

            #TODO: insert runtime stride checks that select the best loop order either here, or in
            # the host code that launched the  kernel (host code probably better spot)

            #indent = " "*(4*d+7)
            #for ipos, i in enumerate(node.inputs):
                #print >> sio, indent, "const float * i%i" % ipos, '= i%i_data', ''
            print >> sio, "}"

        print sio.getvalue()
        return sio.getvalue()

    def c_src_kernel_tiling_less_registers(self, node, nodename):
        """ The kernel applies to problems with <= 5 dimensions """

        nd = node.outputs[0].type.ndim
        n_in = len(node.inputs)
        n_out = len(node.outputs)
        sio = StringIO.StringIO()

        if nd not in (2,):
            return sio.getvalue()

        # print some leading comments to make the code easier to read
        for ipos, i in enumerate(node.inputs):
            print >> sio, "//    Input  ", ipos, str(i.type)
        for ipos, i in enumerate(node.outputs):
            print >> sio, "//    Output ", ipos, str(i.type)
        print >> sio, "static __global__ void kernel_%s_%s_%s_%s(unsigned int numEls" %(
                self.scalar_op.__class__.__name__,
                nodename, 
                id(self),
                'tiling%i_less_registers'%nd)
        if (nd):
            print >> sio, "\t,", ", ".join("const int dim%i" % i for i in xrange(nd))
        #declare inputs
        for ipos, i in enumerate(node.inputs):
            s = ", ".join(["const float * i%i_data_0" % ipos] + list("int i%i_str_%i" % (ipos, d) for d in xrange(nd)))
            print >> sio, "\t,", s
        #declare outputs
        for ipos, i in enumerate(node.outputs):
            s = ", ".join(["float * o%i_data_0" % ipos] + list("int o%i_str_%i" % (ipos, d) for d in xrange(nd)))
            print >> sio, "\t,", s
            #print >> sio, "\t,", ", ".join("int o%i_str_%i" % (ipos, d) for d in xrange(nd))
            #print >> sio, "\t,", "float * o%i_data" % ipos
        print >> sio, "\t)\n{"

        # TODO: Setting these to true makes the function fail SOMETIMES.  I don't know why yet.
        use_shared_stride = False
        use_shared_limits = False

        def decl_limits(nd):
            if use_shared_limits:
                print >> sio, "__shared__ float * limits[%(nd)s];" % locals()

        def stride(io, p, d):
            if use_shared_stride:
                return "s%s_str[%i][%i]" %(io, p, d)
            else:
                return "%s%i_str_%i" %(io, p, d)
        def limits(d):
            if use_shared_limits:
                return "limits[%i]" % d
            else:
                return "limits%i" % d

        def decl_shared_stride(nin, nout, nd):
            if not use_shared_stride:
                return
            print >> sio, """
            __shared__ int si_str[%(nin)s][%(nd)s];
            __shared__ int so_str[%(nout)s][%(nd)s];
            if ((threadIdx.x == 0) && (threadIdx.y == 0)) {
            """ % locals()
            for i in xrange(nin):
                for d in xrange(nd):
                    print >> sio, "si_str[%(i)s][%(d)s] = i%(i)s_str_%(d)s;" %locals()
            for i in xrange(n_out):
                for d in xrange(nd):
                    print >> sio, "so_str[%(i)s][%(d)s] = o%(i)s_str_%(d)s;" %locals()
            print >> sio, "} __syncthreads();"

        def calc_limit(d):
            s = stride('o', 0, d)
            lname = limits(d)
            if use_shared_limits:
                print >> sio, "if ((threadIdx.x == 0) && (threadIdx.y == 0)) {"
                if d == 0:
                    print >> sio, "%(lname)s = o0_data_0 + dim%(d)s * %(s)s;" % locals()
                else:
                    dm1 = d - 1
                    print >> sio, "%(lname)s = o0_data_%(dm1)s + dim%(d)s * %(s)s;" % locals()
                print >> sio, "} __syncthreads();"
            else:
                if d == 0:
                    print >> sio, "const float * %(lname)s = o0_data_0 + dim%(d)s * %(s)s;" % locals()
                else:
                    dm1 = d - 1
                    print >> sio, "const float * %(lname)s = o0_data_%(dm1)s + dim%(d)s * %(s)s;" % locals()

        def decl_ptrs(d, offset):
            dm1 = d - 1
            assert dm1 >= 0
            for i in xrange(n_in):
                s = stride('i', i, d)
                print >> sio, "const float * i%(i)s_data_%(d)s = i%(i)s_data_%(dm1)s + %(offset)s * %(s)s;" %locals()
            for i in xrange(n_out):
                s = stride('o', i, d)
                print >> sio, "float * o%(i)s_data_%(d)s = o%(i)s_data_%(dm1)s + %(offset)s * %(s)s;" %locals()

        def inc_ptrs(d, amt):
            for i in xrange(n_in):
                s = stride('i', i, d)
                print >> sio, "i%(i)s_data_%(d)s += %(amt)s * %(s)s;" %locals()
            for i in xrange(n_out):
                s = stride('o', i, d)
                print >> sio, "o%(i)s_data_%(d)s += %(amt)s * %(s)s;" %locals()

        def while_limit(d):
            lname = limits(d)
            print >> sio, "while (o0_data_%(d)s < %(lname)s) { " % locals()

        def end_while(d):
            print >> sio, "}"

        def task_code(d):
            print >> sio, self.scalar_op.c_code(
                Apply(self.scalar_op,
                    [scalar.Scalar(dtype = input.type.dtype)() for input in node.inputs],
                    [scalar.Scalar(dtype = output.type.dtype)() for output in node.outputs])
                , nodename + '_scalar_'
                , ['i%i_data_%i[0]'%(ipos,d) for ipos, i in enumerate(node.inputs)] 
                , ['o%i_data_%i[0]'%(ipos,d) for ipos, i in enumerate(node.outputs)] 
                , sub=dict(fail='return;')) #TODO: set a failure code somehow!!!

        if nd == 4:
            decl_shared_stride(n_in, n_out, nd)
            decl_limits(nd)
            calc_limit(0)
            inc_ptrs(0, 'blockIdx.x')
            while_limit(0)
            if 1:
                calc_limit(1)
                decl_ptrs(1, 'blockIdx.y')
                while_limit(1)
                if 1:
                    calc_limit(2)
                    decl_ptrs(2, 'threadIdx.y')
                    while_limit(2)
                    if 1:
                        calc_limit(3)
                        decl_ptrs(3, 'threadIdx.x')
                        while_limit(3)
                        if 1:
                            task_code(3)
                            inc_ptrs(3, 'blockDim.x')
                        end_while(3)
                        inc_ptrs(2, 'blockDim.y')
                    end_while(2)
                    inc_ptrs(1, 'gridDim.y')
                end_while(1)
                inc_ptrs(0, 'gridDim.x')
            end_while(0)
            
        print >> sio, "}"
        print sio.getvalue()
        return sio.getvalue()

    def c_src_kernel_Ccontiguous(self, node, nodename):
        nd = node.outputs[0].type.ndim
        sio = StringIO.StringIO()
        #print 'C_SRC_KERNEL', sio.getvalue()

        for ipos, i in enumerate(node.inputs):
            print >> sio, "//    Input  ", ipos, str(i.type)
        for ipos, i in enumerate(node.outputs):
            print >> sio, "//    Output ", ipos, str(i.type)
        print >> sio, "static __global__ void kernel_%s_%s_Ccontiguous (unsigned int numEls" %(self.scalar_op.__class__.__name__,nodename)
        #declare inputs
        for ipos, i in enumerate(node.inputs):
            print >> sio, "\t,", "const float * i%i_data" % ipos
        #declare outputs
        for ipos, i in enumerate(node.outputs):
            print >> sio, "\t,", "float * o%i_data" % ipos
        print >> sio, "\t)\n{"
        print >> sio, "    const int idx = blockIdx.x * blockDim.x + threadIdx.x;"
        print >> sio, "    const int numThreads = blockDim.x * gridDim.x;"
       
        # For each input that is a scalar which has been broadcasted to a tensor,
        #     load it into a local variable
        for ipos, i in enumerate(node.inputs):
            if _logical_scalar(i):
                print >> sio, "    const float ii_i%i_value = i%i_data[0];" % (ipos, ipos)


        #loop over the elements to be treated by this kernel call
        print >> sio, "    for (int i = idx; i < numEls; i += numThreads) {"
        # perform the scalar operation on the input and output references
        #TODO: What if the scalar_op needs support_code??
        task_code = self.scalar_op.c_code(
                Apply(self.scalar_op,
                    [scalar.Scalar(dtype = input.type.dtype)() for input in node.inputs],
                    [scalar.Scalar(dtype = output.type.dtype)() for output in node.outputs])
                , nodename + '_scalar_'
                #, ['i%i_data[i]'%ipos for ipos, i in enumerate(node.inputs)] 
                , get_str_list_logical_scalar(node, data_str='i%i_data[i]')
                , ['o%i_data[i]'%ipos for ipos, i in enumerate(node.outputs)] 
                , sub=dict(fail='return;')) #TODO: set a failure code somehow!!!
        print >> sio, "       ", task_code
        print >> sio, "    }"
        print >> sio, "}"

        #print sio.getvalue()
        return sio.getvalue()

    def c_src_callkernel(self, node, nodename):
        #
        # This function serves three main goals:
        #
        # The first is stride unpacking:
        # it accepts input and output arguments as 
        #    float * , int* 
        # pairs, and it constructs a kernel function call where inputs and arguments are named
        # like 
        #    float *, int, int, int ...
        #
        # The second is to recognize when trailing (right-most in numpy) dimensions can be collapsed as
        # being contiguous... (confusing... read code)
        #
        # The thrid is to make a special case for scalar element. We allow the collapsing of them.
        # In the ccontiguous and not contiguous case, we use registers to lower the number of memory access.

        #TODO: make a special case for broadcasting, to store the data in shared memory.

        nd = node.outputs[0].type.ndim
        id_self = id(self)
        d = dict()
        #input_params and output_params go into the function declaration/definition
        input_params = ", ".join("const float * i%i_data, const int * i%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.inputs)))
        output_params = ", ".join("float * o%i_data, const int * o%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.outputs)))

        #input_args and output_args go into the recursive call.
        input_args = ", ".join("i%i_data, i%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.inputs)))
        output_args = ", ".join("o%i_data, o%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.outputs)))

        prod_dims = '*'.join(["dims[%i]"%di for di in xrange(nd)]+['1'])

        scalar_op=self.scalar_op.__class__.__name__

        sio = StringIO.StringIO()
        print >> sio, """
        static void can_collapse_%(nodename)s(int nd, const int * dims, const int * strides, int collapse[])
        {
            //can we collapse dims[i] and dims[i-1]
            for(int i=nd-1;i>0;i--){
                if(false && dims[i]==1 && strides[i]==0){//
                    collapse[i]=1;
                }else if(false && dims[i-1]==1 && strides[i-1]==0){
                    collapse[i]=1;
                }else   if(strides[i]*dims[i]==strides[i-1]){//the dims nd-1 are not strided again dimension nd
                    collapse[i]=1;
                }else collapse[i]=0;
            }
        }
        """ %locals()
        print >> sio, """
        static int callkernel_%(nodename)s(unsigned int numEls, const int d,
            const int * dims,
            %(input_params)s,
            %(output_params)s)
        {
            numEls = %(prod_dims)s;
        """ %locals()
        if self.verbose:
            print >> sio, """
                std::cerr << "calling kernel_%(scalar_op)s_%(nodename)s_%(id_self)s     w numEls" << numEls << " dims"<< d << "\\n";
            """ %locals()
            print >> sio, 'std::cerr << ' + " << ' ' <<  ".join(['"  "']+list("dims[%i]"%di
                for di in xrange(nd)) + ["'\\n';"])
        if self.verbose>1:
            for ipos in xrange(len(node.inputs)):
                print >> sio, """
                std::cerr << "   %(ipos)s data strides" << 
                """ %locals() + " << ' ' <<  ".join(["i%s_data"%ipos]
                + list("i%s_str[%i]"%(ipos, di) for di in xrange(nd))) + ''' << "\\n"; '''

            for ipos in xrange(len(node.outputs)):
                print >> sio, """
                std::cerr << "   %(ipos)s data strides" << 
                """ %locals() + " << ' ' <<  ".join(["o%s_data"%ipos]
                    + list("o%s_str[%i]"%(ipos, di) for di in xrange(nd))) + ''' << "\\n"; '''

    # collapse contiguous dimensions (ignoring scalars, generic version(collapse any dimensions, right, left, middle))
    # this is a good idea because [we assume that] the output has been allocated c_contiguous

        print >> sio, "int nd_collapse_[%(nd)s] = {"%locals() +','.join(['1' for x in range(nd)]) +"};"
        for ipos in xrange(len(node.inputs)):
            if not _logical_scalar(node.inputs[ipos]):
                print >> sio, """
                    int nd_collapse_%(ipos)s[%(nd)s] = {"""%locals() +','.join(['1' for x in range(nd)]) +"};"
                print >> sio, """
can_collapse_%(nodename)s(%(nd)s, dims, i%(ipos)s_str, nd_collapse_%(ipos)s);
for(int i=0;i<%(nd)s;i++){
if(nd_collapse_%(ipos)s[i]==0)
nd_collapse_[i]=0;
}
                """ %locals()
                if self.verbose>1:
                    print >>sio, """
                    std::cerr<< "nd_collapse_%(ipos)s "<< 
                    """%locals()
                    print >>sio, ' << " " << '.join(["nd_collapse_%(ipos)s["%locals()+str(i)+"]" for i in range(nd)])
                    print >>sio, '<< "\\n";'
                    print >>sio, """
                    std::cerr<< "nd_collapse_ "<< 
                    """%locals()
                    print >>sio, ' << " " << '.join(["nd_collapse_["%locals()+str(i)+"]" for i in range(nd)])
                    print >>sio, '<< "\\n";'
        print >> sio, """
        int nd_collapse=%(nd)s;
        for(int i=1;i<%(nd)s;i++){
        if(nd_collapse_[i]==1)nd_collapse--;
        }
        if(nd_collapse==1 && """%locals()
        print >> sio, " && ".join([ "i%(ipos)s_str[%(nd)s-1]==1 "%locals()for x in range(len(node.inputs))])
        print >> sio,"""){nd_collapse=0;} """
        if self.verbose:
            print >> sio, """std::cerr << "nd_collapse " << nd_collapse << "\\n"; """ %locals()

    # set the new dims.
        print >> sio, "int local_dims[%(nd)s];"%locals()
        print >> sio, """
        for(int i=0;i<%(nd)s;i++){//init new dim
          local_dims[i]=dims[i];
        }
        for(int i=%(nd)s-1;i>0;i--){
          if(nd_collapse_[i]==1){
            local_dims[i-1]*=local_dims[i];//set new dims
            for(int j=i+1;j<%(nd)s;j++)//remove dims i from the array
              local_dims[j-1]=local_dims[j];
          }
        }

        """%locals()

        if self.verbose>1:
            for d in xrange(nd):
                print >> sio, 'std::cerr << "local_dims %(d)s " << local_dims[%(d)s] << "\\n"; '%locals()

        # set the new stride.
        for ipos in xrange(len(node.inputs)):
            print >> sio, """
            int local_i%(ipos)s_str[%(nd)s];
            """%locals()
            print >> sio, """
            for(int i=0;i<%(nd)s;i++){//init new strides
              local_i%(ipos)s_str[i]=i%(ipos)s_str[i];
            }

            for(int i=%(nd)s-1;i>0;i--){
              if(nd_collapse_[i]==1){
                local_i%(ipos)s_str[i-1]=local_i%(ipos)s_str[i];//set new strides
                for(int j=i+1;j<%(nd)s;j++)//remove stride i from the array
                  local_i%(ipos)s_str[j-1]=local_i%(ipos)s_str[j];
                }
            }
            """%locals()


        for ipos in xrange(len(node.outputs)):
            print >> sio, "int local_o%(ipos)s_str[%(nd)s];"%locals()
            print >> sio, """
            for(int i=0;i<%(nd)s;i++){//init new strides
              local_o%(ipos)s_str[i]=o%(ipos)s_str[i];
            }

            for(int i=%(nd)s-1;i>0;i--){
              if(nd_collapse_[i]==1){
                local_o%(ipos)s_str[i-1]=local_o%(ipos)s_str[i];//set new strides
                for(int j=i+1;j<%(nd)s;j++)//remove stride i from the array
                  local_o%(ipos)s_str[j-1]=local_o%(ipos)s_str[j];
                }
            }
            """%locals()

        if self.verbose>1:
            for ipos in ["i"+ str(x) for x in xrange(len(node.inputs))]+["o"+ str(x) for x in xrange(len(node.outputs))]:
                print >> sio, 'std::cerr << " local_%(ipos)s_str " <<'%locals()+' << " " << '.join(["local_%(ipos)s_str[%(x)s]"%locals() for x in range(nd)])+'<<"\\n";'


        def launch_Ccontiguous(nodename, id_self, scalar_op):
            kernel_call_args = ["numEls"]
            for ipos in xrange(len(node.inputs)):
                kernel_call_args.append("i%i_data"%ipos)
            for ipos in xrange(len(node.outputs)):
                kernel_call_args.append("o%i_data"%ipos)
            kernel_call_args = ", ".join(kernel_call_args)
            verb=""
            if self.verbose:
                verb='std::cerr << "   Running ccontiguous version\\n";'
            print >> sio, """
                int threads_per_block = std::min(numEls, (unsigned int)NUM_VECTOR_OP_THREADS_PER_BLOCK);
                int n_blocks = std::min(numEls/threads_per_block + (numEls %% threads_per_block?1:0), (unsigned int)NUM_VECTOR_OP_BLOCKS);
                kernel_%(scalar_op)s_%(nodename)s_Ccontiguous<<<n_blocks, threads_per_block>>>(%(kernel_call_args)s);

                //std::cerr << "calling callkernel returned\\n";
                CNDA_THREAD_SYNC;
                cudaError_t err = cudaGetLastError();
                if( cudaSuccess != err) 
                {
                    PyErr_Format(PyExc_RuntimeError, "Cuda error: %%s: %%s.\\n", "Elemwise %(nodename)s %(scalar_op)s", cudaGetErrorString(err));
                    return -1;
                
                }
                %(verb)s
                return 0;
                """ %locals()

        def launch_General(nodename, id_self, scalar_op, force_nd):
            # kernel_call_args are used to invoke the cuda kernel
            local="local_"
            kernel_call_args = ["numEls"]
            kernel_call_args.extend(local+"dims[%i]"%di for di in xrange(force_nd))
            for ipos in xrange(len(node.inputs)):
                kernel_call_args+=["i%i_data"%ipos] + list(local+"i%i_str[%i]"%(ipos, di) for di in xrange(force_nd))
                #strides = ", ".join("i%i_str[%i]"%(ipos, di) for di in xrange(force_nd))
                #kernel_call_args.append( "%s, i%i_data" % (strides, ipos))
            for ipos in xrange(len(node.outputs)):
                kernel_call_args+=["o%i_data"%ipos] + list(local+"o%i_str[%i]"%(ipos, di) for di in xrange(force_nd))
                #strides = ", ".join("o%i_str[%i]"%(ipos, di) for di in xrange(force_nd))
                #kernel_call_args.append( "%s, o%i_data" % (strides, ipos))
            if self.verbose:
                print >> sio, """
                    std::cerr << "   Running general version with %(force_nd)s  dims\\n";
                    """%locals()
                print >> sio, "std::cerr << "+ ' << " " << '.join(kernel_call_args)+' << "\\n";'
                #std::cerr << numEls << dims[0] << i0_data, i0_str[0] << o0_data, o0_str[0]\n;
                
            kernel_call_args = ", ".join(kernel_call_args)
            
            print >> sio, """
                int threads_per_block = std::min(numEls, (unsigned int)NUM_VECTOR_OP_THREADS_PER_BLOCK);
                int n_blocks = std::min(numEls/threads_per_block + (numEls %% threads_per_block?1:0), (unsigned int)NUM_VECTOR_OP_BLOCKS);
                kernel_%(scalar_op)s_%(nodename)s_%(id_self)s_%(force_nd)s<<<n_blocks, threads_per_block>>>(%(kernel_call_args)s);
                CNDA_THREAD_SYNC;
                cudaError_t err = cudaGetLastError();
                if( cudaSuccess != err) 
                {
                    PyErr_Format(PyExc_RuntimeError, "Cuda error: %%s: %%s.\\n", "Elemwise %(nodename)s %(scalar_op)s", cudaGetErrorString(err));
                    return -1;
                
                }                         
                return 0;
                """ %locals()

        print >> sio, "switch (nd_collapse==0?0:min(%(nd)s,nd_collapse)) {"%locals()
        print >> sio, "case 0: {"
        launch_Ccontiguous(nodename, id_self, scalar_op)
        print >> sio, "        } break;"
        for i in range(1, nd+1):
            print >> sio, "case "+str(i)+": {"
            launch_General(nodename, id_self, scalar_op, i)
            print >> sio, "        } break;"
                                   
        print >> sio, "}"#end case
        print >> sio, "}"#end fct

        #N.B. cudaGetLastError is called by c_code
        return sio.getvalue()


    def c_support_code_apply(self, node, nodename):
        nd = node.outputs[0].type.ndim
        return "".join(
            [self.c_src_kernel(node, nodename,x) for x in range(1,nd+1)]+
            [
            self.c_src_kernel_Ccontiguous(node, nodename),
            self.c_src_callkernel(node, nodename),
            ])

    def c_code(self, node, nodename, inputs, outputs, sub):
        d = dict(sub)
        nd = node.outputs[0].type.ndim
        d.update(locals())
        sio = StringIO.StringIO()
        nin = len(inputs)
        nout = len(outputs)
        fail = sub['fail']
        opname = str(self.scalar_op)
        initial_dims = ','.join('1' for i in xrange(nd))
        if 1 or self.scalar_op == scalar.pow:
            print >> sio, """
        //std::cerr << "C_CODE %(opname)s START\\n";
        //standard elemwise size checks
            """ %locals()
        print >> sio, """
        int dims[%(nd)s] = {%(initial_dims)s};
        """ %locals()

        #check that all inputs have valid dimensions
        for iname in inputs:
            print >> sio, """
        //std::cerr << "C_CODE %(opname)s checking input %(iname)s\\n";
        if (%(nd)s != %(iname)s->nd)
        {
            PyErr_Format(PyExc_TypeError, "need %(nd)s dims, not %%i", %(iname)s->nd);
            %(fail)s;
        }
        for (int i = 0; i< %(nd)s; ++i)
        {
            dims[i] = (dims[i] == 1) ? CudaNdarray_HOST_DIMS(%(iname)s)[i] : dims[i];
            if ((CudaNdarray_HOST_DIMS(%(iname)s)[i] != 1) && (dims[i] != CudaNdarray_HOST_DIMS(%(iname)s)[i]))
            {
                //std::cerr << "C_CODE %(opname)s checking input %(iname)s failed\\n";
                PyErr_Format(PyExc_TypeError, "GpuElemwise input has incompatible dim[%%i] == %%i, where output has size %%i",
                    i,
                    CudaNdarray_HOST_DIMS(%(iname)s)[i],
                    dims[i]
                    );
                %(fail)s;
            }
        }
            """ %locals()

        #check that all outputs have valid dimensions
        for oname in outputs:
            print >> sio, """
        for (int i = 0; (i< %(nd)s) && (%(oname)s); ++i) {
            if (dims[i] != CudaNdarray_HOST_DIMS(%(oname)s)[i])
            {
                Py_DECREF(%(oname)s);
                %(oname)s = NULL;
            }
        }
        if (NULL == %(oname)s)
        {
            %(oname)s = (CudaNdarray*)CudaNdarray_new_null();
            if (!%(oname)s)
            { 
                //error string already set
                %(fail)s;
            }
            if (CudaNdarray_alloc_contiguous(%(oname)s, %(nd)s, dims))
            {
                //error string already set
                Py_DECREF(%(oname)s);
                %(oname)s = NULL;
                %(fail)s;
            }
        }
        //std::cerr << "ELEMWISE NEW %(oname)s nd" << %(oname)s->nd << "\\n";
        //std::cerr << "ELEMWISE NEW %(oname)s data" << %(oname)s->devdata << "\\n";
        """ % locals()
        print >> sio, """
        { 
            //new block so that failure gotos don't skip over variable initialization
            //std::cerr << "calling callkernel\\n";
            if (callkernel_%(nodename)s(1, 0, dims
            """ % locals()
        for iname in inputs:
            print >> sio, """
                        , CudaNdarray_DEV_DATA(%(iname)s), CudaNdarray_HOST_STRIDES(%(iname)s)
            """ % locals()
        for oname in outputs:
            print >> sio, """
                        , CudaNdarray_DEV_DATA(%(oname)s), CudaNdarray_HOST_STRIDES(%(oname)s)
            """ % locals()
        print >> sio, """
                        ))
            {
                 // error
            """
        for oname in outputs:
            print >> sio, """
                Py_DECREF(%(oname)s);
                %(oname)s = NULL;
                """ % locals()
        print >> sio, """
                %(fail)s;
            }
            else // no error
            {
            }
        }
        //std::cerr << "C_CODE %(opname)s END\\n";
        """ % locals()
        #print sio.getvalue()
        return sio.getvalue()

    def c_support_code(self):
        return """
        #define INTDIV_POW2(a, b) (a >> b)
        #define INTMOD_POW2(a, b) (a & ((1<<b)-1))
        """



class ExternAlgo(object):
    def externalgo_c_support_code_apply(self, node, nodename):
        nd = node.outputs[0].type.ndim
        n_inputs = len(node.inputs)
        n_outputs = len(node.outputs)
        id_self = id(self)
        d = dict()
        #input_params and output_params go into the function declaration/definition
        input_params = ", ".join("const float * i%i_data, const int * i%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.inputs)))
        output_params = ", ".join("float * o%i_data, const int * o%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.outputs)))

        #input_args and output_args go into the recursive call.
        input_args = ", ".join("i%i_data, i%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.inputs)))
        output_args = ", ".join("o%i_data, o%i_str"%(ipos, ipos) 
                for ipos in xrange(len(node.outputs)))

        prod_dims = '*'.join("dims[%i]"%di for di in xrange(nd))

        scalar_op=self.scalar_op.__class__.__name__

        apply_task_code = self.scalar_op.c_code(
                Apply(self.scalar_op,
                    [scalar.Scalar(dtype = input.type.dtype)() for input in node.inputs],
                    [scalar.Scalar(dtype = output.type.dtype)() for output in node.outputs])
                , nodename + '_scalar_'
                , ['x[%i][0]'%ipos for ipos, i in enumerate(node.inputs)] 
                , ['z[%i][0]'%ipos for ipos, i in enumerate(node.outputs)] 
                , sub=dict(fail='return;')) #TODO: set a failure code somehow!!!

        ### NOTE WELL: log2_dims is not initialized on input to this function... it is meant as
        ### storage space where the log2_dims *could* be computed and stored.
        sio = StringIO.StringIO()
        print >> sio, """
        #include "elemwise.cuh"

        template <int nx, typename Tx, int nz, typename Tz>
        class ElemwiseFn_%(scalar_op)s
        {
        public:
            static __device__ void apply(const Tx**x, Tz**z)
            {
                %(apply_task_code)s
            }  
        };

        static void callkernel_%(nodename)s(unsigned int numEls, const int d,
            const int * dims, const int * log2_dims,
            %(input_params)s,
            %(output_params)s)
        {
            const float * inputs[%(n_inputs)s];
            float * outputs[%(n_outputs)s];
            const int * input_strides[%(n_inputs)s];
            const int * output_strides[%(n_inputs)s];
            
        """ %locals()
        for ipos, i in enumerate(node.inputs):
            print >> sio, """
            inputs[%(ipos)s] = i%(ipos)s_data;
            input_strides[%(ipos)s] = i%(ipos)s_str;
            """ %locals()
        for ipos, i in enumerate(node.outputs):
            print >> sio, """
            outputs[%(ipos)s] = o%(ipos)s_data;
            output_strides[%(ipos)s] = o%(ipos)s_str;
            """ %locals()
        print >> sio, """
            cnda_elemwise<float, float, 
                    ElemwiseFn_%(scalar_op)s<%(n_inputs)s, typeof(i0_data[0]), %(n_outputs)s, typeof(o0_data[0])>
                    , %(n_inputs)s, %(n_outputs)s, %(nd)s> (
                 dims,
                 inputs,
                 input_strides,
                 outputs,
                 output_strides
            );
        }
        """ %locals()
        print sio.getvalue()
        return sio.getvalue()

