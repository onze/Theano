#include <Python.h>
#include <structmember.h>

#include <numpy/arrayobject.h>
#include <iostream>

#include "cuda_ndarray.cuh"
#ifndef DONT_UNROLL
#define UNROLL_LOOP
#endif

/////////////////////////
// Static helper methods
/////////////////////////

static void
CudaNdarray_null_init(CudaNdarray*self)
{
    self->base = NULL;
    self->nd = -1;
    self->host_structure = NULL;
    self->data_allocated = 0;
    self->dev_structure_fresh = 1;
    self->dev_structure = NULL;
    self->devdata = NULL;
}

static int
CudaNdarray_uninit(CudaNdarray*self)
{
    int rval = 0;
    if (self->data_allocated) {
        assert(self->devdata);
        cublasFree(self->devdata);
        if (CUBLAS_STATUS_SUCCESS != cublasGetError())
        {
            std::cerr << "!!!! error freeing device memory\n";
            rval = -1;
        }
        self->devdata = NULL;
        self->data_allocated = 0;
    }
    if (self->dev_structure)
    {
        cublasFree(self->dev_structure);
        if (CUBLAS_STATUS_SUCCESS != cublasGetError())
        {
            std::cerr << "!!!! error freeing device memory\n";
            rval = -1;
        }
        self->dev_structure = NULL;
    }
    if (self->host_structure)
    {
        free(self->host_structure);
        self->host_structure = NULL;
    }
    self->nd = -1;
    Py_XDECREF(self->base);
    self->base = NULL;
    return rval;
}


//make the rightmost coords change fastest 
//TODO: why does a downward for-loop not work????
//TODO: use the log2_dims and driver code to remove / and %
//TODO: skip the last division (when d == 0) 
#define decl_k_elemwise_unary_rowmajor(name, F) \
__global__ void name (unsigned int numEls,  \
        unsigned int nd, \
        const int * dim,  \
        const float * a_data, const int * a_str, \
        float * z_data, const int * z_str) \
{ \
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x; \
    const unsigned int numThreads = blockDim.x * gridDim.x; \
 \
    for (unsigned int i = idx; i < numEls; i += numThreads) \
    { \
        unsigned int ii = i; \
        const float * a_i = a_data; \
        float * z_i = z_data; \
        for (unsigned int _d = 0; _d < nd; ++_d) \
        { \
            unsigned int d = nd - _d-1;  \
            unsigned int i_d = ii % dim[d]; /* i_d is our position in the d'th dimension   */ \
            ii = ii / dim[d]; \
            a_i += i_d * a_str[d]; /* increment our a and z pointers by i_d elements */ \
            z_i += i_d * z_str[d]; \
        } \
        z_i[0] = F(a_i[0]); \
    } \
} 

template<typename T> __device__ T unary_copy(T a) { return a; }
decl_k_elemwise_unary_rowmajor(k_elemwise_unary_rowmajor_copy, unary_copy<float>)

template<typename T> __device__ T unary_exp(T a) { return exp(a); }
decl_k_elemwise_unary_rowmajor(k_elemwise_unary_rowmajor_exp, unary_exp<float>)

/////////////////////////////
// Satisfying reqs to be Type
/////////////////////////////

static void
CudaNdarray_dealloc(CudaNdarray* self)
{
    //std::cerr << "CudaNdarray dealloc " << self << " " << self->devdata << '\n';
    CudaNdarray_uninit(self);
    self->ob_type->tp_free((PyObject*)self);
}

static PyObject *
CudaNdarray_new(PyTypeObject *type, PyObject *args, PyObject *kwds)
{
    CudaNdarray *self;

    self = (CudaNdarray *)type->tp_alloc(type, 0);
    if (self != NULL)
    {
        CudaNdarray_null_init(self);
    }
    return (PyObject *)self;
}
static int
CudaNdarray_init(CudaNdarray *self, PyObject *args, PyObject *kwds)
{
    PyObject *arr=NULL;

    if (! PyArg_ParseTuple(args, "O", &arr))
        return -1; 
    if (! PyArray_Check(arr))
    {
        PyErr_SetString(PyExc_TypeError, "PyArray arg required");
        return -1;
    }
    int rval = CudaNdarray_CopyFromArray(self, (PyArrayObject*)arr);
    return rval;
}
static PyMemberDef CudaNdarray_members[] = 
{
    /*
    {"first", T_OBJECT_EX, offsetof(CudaNdarray, first), 0,
     "first name"},
    {"last", T_OBJECT_EX, offsetof(CudaNdarray, last), 0,
     "last name"},
    {"number", T_INT, offsetof(CudaNdarray, number), 0,
     "noddy number"},
     */
    {NULL}  /* Sentinel */
};

PyObject * CudaNdarray_CreateArrayObj(CudaNdarray * self)
{
    int verbose = 0;
    if ((self->nd < 0) || (self->devdata == 0))
    {
        PyErr_SetString(PyExc_ValueError, "can't copy from un-initialized CudaNdarray");
        return NULL;
    }
    CudaNdarray * contiguous_self = NULL;
    if (CudaNdarray_is_c_contiguous(self))
    {
        contiguous_self = self;
        Py_INCREF(contiguous_self);
        if (verbose) std::cerr << "CreateArrayObj already contiguous" << contiguous_self << '\n';
    }
    else
    {
        contiguous_self = (CudaNdarray*)CudaNdarray_Copy(self);
        if (verbose) std::cerr << "CreateArrayObj created contiguous" << contiguous_self << '\n';
    }
    if (!contiguous_self)
    {
        return NULL;
    }

    npy_intp * npydims = (npy_intp*)malloc(self->nd * sizeof(npy_intp));
    assert (npydims);
    for (int i = 0; i < self->nd; ++i) npydims[i] = (npy_intp)(CudaNdarray_HOST_DIMS(self)[i]);
    PyObject * rval = PyArray_SimpleNew(self->nd, npydims, REAL_TYPENUM);
    free(npydims);
    if (!rval)
    {
        Py_DECREF(contiguous_self);
        return NULL;
    }

    assert (PyArray_ITEMSIZE(rval) == sizeof(real));

    cublasGetVector(PyArray_SIZE(rval), sizeof(real),
            contiguous_self->devdata, 1, 
            PyArray_DATA(rval), 1);
    CNDA_THREAD_SYNC;

    if (CUBLAS_STATUS_SUCCESS != cublasGetError())
    {
        PyErr_SetString(PyExc_RuntimeError, "error copying data to host");
        Py_DECREF(rval);
        rval = NULL;
    }

    Py_DECREF(contiguous_self);
    return rval;
}
PyObject * CudaNdarray_Copy(CudaNdarray * self)
{
    PyObject * rval = CudaNdarray_new_null();
    if ((!rval) or (-1 == self->nd))
    {
        return rval;
    }
    if (CudaNdarray_alloc_contiguous((CudaNdarray*)rval, self->nd, CudaNdarray_HOST_DIMS(self)))
    {
        Py_DECREF(rval);
        return NULL;
    }
    if (CudaNdarray_CopyFromCudaNdarray((CudaNdarray*)rval, self))
    {
        Py_DECREF(rval);
        return NULL;
    }
    return rval;
}
PyObject * CudaNdarray_DeepCopy(CudaNdarray * self, PyObject * memo)
{
    assert(PyDict_Check(memo));
    PyObject * selfkey = PyInt_FromLong((long)self);
    assert(selfkey);
    if (PyDict_Contains(memo, selfkey))
    {
        PyObject * rval = PyDict_GetItem(memo, selfkey);
        Py_DECREF(selfkey);
        Py_XINCREF(rval);
        return rval;
    }
    else
    {
        PyObject * rval = CudaNdarray_Copy(self);
        //std::cerr << "DeepCopy created " << rval << " devdata " << ((CudaNdarray*)rval)->devdata << "\n";
        if (NULL == rval)
        {
            Py_DECREF(selfkey);
            return NULL;
        }
        if (PyDict_SetItem(memo, selfkey, rval))
        {
            Py_DECREF(rval);
            Py_DECREF(selfkey);
            return NULL;
        }
        Py_DECREF(selfkey);
        return rval;
    }
}
PyObject * CudaNdarray_ReduceSum(CudaNdarray * self, PyObject * py_reduce_mask)
{
    if (!PySequence_Check(py_reduce_mask))
    {
        PyErr_SetString(PyExc_TypeError, "reduce_mask must be sequence of ints");
        return NULL;
    }
    int len = PySequence_Length(py_reduce_mask);
    if (len != self->nd)
    {
        PyErr_SetString(PyExc_TypeError, "length of reduce_mask must match self->nd");
        return NULL;
    }
    CudaNdarray * self_sum = (CudaNdarray*)CudaNdarray_new_null();
    if (!self_sum)
    {
        return NULL;
    }
    int * dimshuffle_pattern = (int*)malloc(len * 2 * sizeof(int));
    int * sum_dims = dimshuffle_pattern + len;
    int n_remaining_dims = 0;
    if (!dimshuffle_pattern)
    {
        Py_DECREF(self_sum);
        PyErr_SetString(PyExc_MemoryError, "failed to alloc internal storage");
        return NULL;
    }
    for (int i = 0; i < len; ++i)
    {
        PyObject *o_i = PySequence_GetItem(py_reduce_mask, i);
        int o_i_int = PyInt_AsLong(o_i);
        Py_XDECREF(o_i);
        if (PyErr_Occurred())
        {
            Py_DECREF(self_sum);
            free(dimshuffle_pattern);
            return NULL;
        }
        if (o_i_int) // this is a dimension over which we are reducing
        {
            sum_dims[i] = 1;
        }
        else
        {
            sum_dims[i] = CudaNdarray_HOST_DIMS(self)[i];
            dimshuffle_pattern[n_remaining_dims++] = i;
        }
    }
    if (0   || CudaNdarray_alloc_contiguous(self_sum, len, sum_dims)
            || CudaNdarray_reduce_sum(self_sum, self)
            || CudaNdarray_dimshuffle(self_sum, n_remaining_dims, dimshuffle_pattern))
    {
        Py_DECREF(self_sum);
        free(dimshuffle_pattern);
        return NULL;
    }
    free(dimshuffle_pattern);
    return (PyObject*)self_sum;
}

__global__ void k_copy_reshape_rowmajor(unsigned int numEls, 
        unsigned int a_nd, const float * a_data, const int * a_dim, const int * a_str,
        unsigned int z_nd, float * z_data, const int * z_dim, const int * z_str)
{
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < numEls; i += numThreads)
    {
        const float * a_i = a_data;
        unsigned int a_ii = i;
        for (unsigned int _d = 0; _d < a_nd; ++_d) //make the rightmost coords change fastest
        {
            unsigned int d = a_nd - _d-1; 
            unsigned int a_i_d = a_ii % a_dim[d];
            a_ii = a_ii / a_dim[d];
            a_i += a_i_d * a_str[d];
        }
        unsigned int z_ii = i;
        float * z_i = z_data;
        for (unsigned int _d = 0; _d < z_nd; ++_d) //make the rightmost coords change fastest
        {
            unsigned int d = z_nd - _d-1; 
            //i tried to make the for loop count down, but it didn't work!?
            unsigned int z_i_d = z_ii % z_dim[d];
            z_i += z_i_d * z_str[d];
            z_ii = z_ii / z_dim[d];
        }
        z_i[0] = a_i[0]; //copy one lousy float!
    }
}
PyObject * CudaNdarray_Reshape(CudaNdarray * self, PyObject * shape)
{
    // check shape tuple
    if (!PyTuple_Check(shape))
    {
        PyErr_SetString(PyExc_TypeError, "shape must be tuple of integers");
        return NULL;
    }
    // copy shape to integer array
    unsigned int rval_nd = PyTuple_Size(shape);
    unsigned int * rval_dims = (unsigned int*)malloc(rval_nd * sizeof(int));
    unsigned int rval_size = 1;
    for (int i = 0; i < rval_nd; ++i)
    {
        rval_dims[i] = PyInt_AsLong(PyTuple_GetItem(shape, i)); //GetItem returns borrowed reference
        if (PyErr_Occurred()) //error in AsLong
        {
            free(rval_dims);
            return NULL;
        }
	if(rval_dims[i]<=0){
	  PyErr_Format(PyExc_ValueError, "Reshape has invalid dimension %i (must be >0)",rval_dims[i]);
	  free(rval_dims);
	  return NULL;
	}
        rval_size = rval_size * rval_dims[i];
    }
    // calculate new size, assert same as old size
    if (rval_size != CudaNdarray_SIZE(self))
    {
        PyErr_SetString(PyExc_ValueError, "size must remain unchanged");
        free(rval_dims);
        return NULL;
    }

    if(CudaNdarray_is_c_contiguous(self))
    {
        //return a view, not a copy
        CudaNdarray * rval = (CudaNdarray * )CudaNdarray_New(rval_nd);
	
	if (!rval || 0 != rval->data_allocated
	    ||CudaNdarray_set_device_data(rval, CudaNdarray_DEV_DATA(self), self))
	  {
	    Py_XDECREF(rval);
	    free(rval_dims);
	    return NULL;
	  }
	//set dim and stride
	int size = 1;
	for (int i = rval_nd-1; i >= 0; --i)
	  {
	    CudaNdarray_set_stride(rval, i, (rval_dims[i] == 1) ? 0 : size);
	    CudaNdarray_set_dim(rval, i, rval_dims[i]);
	    size = size * rval_dims[i];
	  }
	free(rval_dims);
	return (PyObject*)rval;
    }

    // allocate new space (TODO: test to see if we can re-use old one)
    CudaNdarray * rval = (CudaNdarray * )CudaNdarray_new_null();
    if (!rval || CudaNdarray_alloc_contiguous(rval, rval_nd, rval_dims))
    {
        Py_XDECREF(rval);
        free(rval_dims);
        return NULL;
    }

    // call worker routine
    unsigned int threads_per_block = std::min(rval_size, (unsigned int)NUM_VECTOR_OP_THREADS_PER_BLOCK);
    unsigned int n_blocks = std::min(ceil_intdiv(rval_size,threads_per_block), (unsigned int)NUM_VECTOR_OP_BLOCKS);
    k_copy_reshape_rowmajor<<<n_blocks,threads_per_block>>>(
            rval_size, 
            self->nd, 
            CudaNdarray_DEV_DATA(self), CudaNdarray_DEV_DIMS(self), CudaNdarray_DEV_STRIDES(self),
            rval->nd,
            CudaNdarray_DEV_DATA(rval), CudaNdarray_DEV_DIMS(rval), CudaNdarray_DEV_STRIDES(rval));

    CNDA_THREAD_SYNC;
    cudaError_t err = cudaGetLastError();
    if( cudaSuccess != err) 
    {
        Py_DECREF(rval);
        PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s.\n", "k_copy_reshape_rowmajor", cudaGetErrorString(err));
        free(rval_dims);
        return NULL;
    }                         
    free(rval_dims);
    return (PyObject*)rval;
}
PyObject * CudaNdarray_View(CudaNdarray * self)
{
    CudaNdarray * rval = (CudaNdarray*)CudaNdarray_New(self->nd);
    if (!rval || CudaNdarray_set_device_data(rval, CudaNdarray_DEV_DATA(self), self))
    {
        Py_XDECREF(rval);
        rval = NULL;
    }
    else
    {
        for (int i = 0; i < self->nd; ++i)
        {
            CudaNdarray_set_dim(rval, i, CudaNdarray_HOST_DIMS(self)[i]);
            CudaNdarray_set_stride(rval, i, CudaNdarray_HOST_STRIDES(self)[i]);
        }
    }
    return (PyObject*)rval;
}
PyObject * CudaNdarray_SetStride(CudaNdarray * self, PyObject *args)
{
    int pos, stride;
    if (! PyArg_ParseTuple(args, "ii", &pos, &stride))
        return NULL; 
    if ((pos < 0) || (pos >= self->nd))
    {
        PyErr_Format(PyExc_ValueError, "position argument out of legal range [0, %i)", self->nd);
        return NULL;
    }
    CudaNdarray_set_stride(self, pos, stride);
    if (cnda_copy_structure_to_device(self))
    {
        return NULL;
    }
    Py_INCREF(Py_None);
    return Py_None;
}
PyObject * CudaNdarray_SetShapeI(CudaNdarray * self, PyObject *args)
{
    int pos, dim;
    if (! PyArg_ParseTuple(args, "ii", &pos, &dim))
        return NULL; 
    if ((pos < 0) || (pos >= self->nd))
    {
        PyErr_Format(PyExc_ValueError, "position argument out of legal range [0, %i)", self->nd);
        return NULL;
    }
    CudaNdarray_set_dim(self, pos, dim);
    if (cnda_copy_structure_to_device(self))
    {
        return NULL;
    }
    Py_INCREF(Py_None);
    return Py_None;
}

static PyObject *
CudaNdarray_exp(CudaNdarray* self)
{
    CudaNdarray * rval = (CudaNdarray *)CudaNdarray_new_null();
    if ((NULL == rval) || CudaNdarray_alloc_contiguous(rval, self->nd, CudaNdarray_HOST_DIMS(self)))
    {
        Py_XDECREF(rval);
        return NULL;
    }
    unsigned int size = 1;
    for (int i = 0; i < self->nd; i++)
    {
        size *= (unsigned int) CudaNdarray_HOST_DIMS(self)[i];
    }
    unsigned int threads_per_block = std::min(size, (unsigned int)NUM_VECTOR_OP_THREADS_PER_BLOCK);
    unsigned int n_blocks = std::min(ceil_intdiv(size,threads_per_block), (unsigned int)NUM_VECTOR_OP_BLOCKS);
    k_elemwise_unary_rowmajor_exp<<<n_blocks,threads_per_block>>>(size, self->nd, CudaNdarray_DEV_DIMS(self), 
            CudaNdarray_DEV_DATA(self), CudaNdarray_DEV_STRIDES(self),
            CudaNdarray_DEV_DATA(rval), CudaNdarray_DEV_STRIDES(rval));

    //TODO: don't do this right away, do it when we need the result
    CNDA_THREAD_SYNC;
    cudaError_t err = cudaGetLastError();
    if( cudaSuccess != err) 
    {
        Py_DECREF(rval);
        PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s.\n", "kExp", cudaGetErrorString(err));
        return NULL;
    }                         

    return (PyObject*)rval;
}
static PyMethodDef CudaNdarray_methods[] = 
{
    {"__array__", 
        (PyCFunction)CudaNdarray_CreateArrayObj, METH_NOARGS,
        "Copy from the device to a numpy ndarray"},
    {"__copy__", 
        (PyCFunction)CudaNdarray_Copy, METH_NOARGS,
        "Create a copy of this object"},
    {"__deepcopy__", 
        (PyCFunction)CudaNdarray_DeepCopy, METH_O,
        "Create a copy of this object"},
    {"reduce_sum",
        (PyCFunction)CudaNdarray_ReduceSum, METH_O,
        "Reduce over the given dimensions by summation"},
    {"exp",
        (PyCFunction)CudaNdarray_exp, METH_NOARGS,
        "Return the exponential of all elements"},
    {"reshape",
        (PyCFunction)CudaNdarray_Reshape, METH_O, 
        "Return a reshaped view (or copy) of this ndarray\n\
            The required argument is a tuple of integers specifying the shape of the new ndarray."},
    {"view",
        (PyCFunction)CudaNdarray_View, METH_NOARGS,
        "Return an alias of this ndarray"},
    {"_set_stride",
        (PyCFunction)CudaNdarray_SetStride, METH_VARARGS,
        "For integer arguments (i, s), set the 'i'th stride to 's'"},
    {"_set_shape_i",
        (PyCFunction)CudaNdarray_SetShapeI, METH_VARARGS,
        "For integer arguments (i, s), set the 'i'th shape to 's'"},
    {NULL, NULL, NULL, NULL}  /* Sentinel */
};


////////////////////
// Number protocol
////////////////////

__global__ void kAdd_contiguous(float* a, float* b, float* dest, unsigned int numEls) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < numEls; i += numThreads) {
        dest[i] = a[i] + b[i];
    }
}
static PyObject *
CudaNdarray_add(PyObject* py_self, PyObject * py_other)
{
    if (! CudaNdarray_Check(py_self)) {
        PyErr_SetString(PyExc_TypeError, "need a CudaNdarray on left");
        return NULL;
    }
    if (! CudaNdarray_Check(py_other)) {
        PyErr_SetString(PyExc_TypeError, "need a CudaNdarray on right");
        return NULL;
    }
    CudaNdarray * self = (CudaNdarray *)py_self;
    CudaNdarray * other = (CudaNdarray *)py_other;
    if(!CudaNdarray_is_c_contiguous(self) || !CudaNdarray_is_c_contiguous(other)){
        PyErr_SetString(PyExc_TypeError, "We have implementet only the c_contiguous version for now.");
        return NULL;      
    }

    //standard elemwise size checks
    if (self->nd != other->nd)
    {
        PyErr_SetString(PyExc_TypeError, "need same number of dims");
        return NULL;
    }
    //standard elemwise dim checks
    unsigned int size = 1;
    for (int i = 0; i< self->nd; ++i)
    {
        if (CudaNdarray_HOST_DIMS(self)[i] != CudaNdarray_HOST_DIMS(other)[i])
        {
            PyErr_SetString(PyExc_TypeError, "need same dimensions");
            return NULL;
        }
        size *= (unsigned int) CudaNdarray_HOST_DIMS(self)[i];
    }
    CudaNdarray * rval = (CudaNdarray *)CudaNdarray_new_null();
    if (!rval || CudaNdarray_alloc_contiguous(rval, self->nd, CudaNdarray_HOST_DIMS(self)))
    {
        Py_XDECREF(rval);
        return NULL;
    }

    int threads_per_block = std::min(size, (unsigned int)NUM_VECTOR_OP_THREADS_PER_BLOCK);
    int n_blocks = std::min(ceil_intdiv(size,(unsigned int)threads_per_block), (unsigned int)NUM_VECTOR_OP_BLOCKS);
    kAdd_contiguous<<<n_blocks,threads_per_block>>>(
            self->devdata, other->devdata, rval->devdata, size);
    CNDA_THREAD_SYNC;
    cudaError_t err = cudaGetLastError();
    if( cudaSuccess != err) 
    {
        PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s.\n", "kAdd", cudaGetErrorString(err));
        Py_DECREF(rval);
        return NULL;
    }
    return (PyObject *) rval;
}
__global__ void k_iAdd_3(const int d0, const int d1, const int d2,
        float* a, const int sA0, const int sA1, const int sA2,
        const float* b, const int sB0, const int sB1, const int sB2)
{
    for (int i0 = blockIdx.x; i0 < d0; i0 += gridDim.x)
    {
        for (int i1 = blockIdx.y; i1 < d1; i1 += gridDim.y)
        {
            for (int i2 = threadIdx.x; i2 < d2; i2 += blockDim.x)
            {
                a[i0*sA0 + i1*sA1 + i2*sA2] += b[i0*sB0 + i1*sB1 + i2*sB2];
            }
        }
    }
}
__global__ void k_iAdd_4(const int d0, const int d1, const int d2, const int d3,
			 float* a, const int sA0, const int sA1,
			 const int sA2, const int sA3,
			 const float* b, const int sB0, const int sB1,
			 const int sB2, const int sB3)
{
    for (int i0 = blockIdx.x; i0 < d0; i0 += gridDim.x)
    {
        for (int i1 = blockIdx.y; i1 < d1; i1 += gridDim.y)
        {
            for (int i2 = threadIdx.x; i2 < d2; i2 += blockDim.x)
            {
	      for (int i3 = threadIdx.y; i3 < d3; i3 += blockDim.y)
		{
		  a[i0*sA0 + i1*sA1 + i2*sA2 + i3*sA3] += b[i0*sB0 + i1*sB1 + i2*sB2 + i3*sB3];
		}
            }
        }
    }
}
/*
 * We need this inplace Add to support IncSubTensor
 */
static PyObject *
CudaNdarray_inplace_add(PyObject* py_self, PyObject * py_other)
{
    int verbose = 0;
    if (verbose) fprintf(stderr, "INPLACE ADD");
    if (! CudaNdarray_Check(py_self)) {
        PyErr_SetString(PyExc_TypeError, "need a CudaNdarray on left");
        return NULL;
    }
    if (! CudaNdarray_Check(py_other)) {
        PyErr_SetString(PyExc_TypeError, "need a CudaNdarray on right");
        return NULL;
    }
    CudaNdarray * self = (CudaNdarray *)py_self;
    CudaNdarray * other = (CudaNdarray *)py_other;

    //standard elemwise size checks
    if (self->nd != other->nd)
    {
        PyErr_SetString(PyExc_TypeError, "need same number of dims");
        return NULL;
    }
    //standard elemwise dim checks
    unsigned int size = 1;
    for (int i = 0; i< self->nd; ++i)
    {
        if ((CudaNdarray_HOST_DIMS(self)[i] != CudaNdarray_HOST_DIMS(other)[i])
            && (CudaNdarray_HOST_DIMS(other)[i] != 1))
        {
            PyErr_SetString(PyExc_TypeError, "need same dimensions (or broadcastable dimension)");
            return NULL;
        }
        size *= (unsigned int) CudaNdarray_HOST_DIMS(self)[i];
    }

    switch(self->nd)
    {
        case 1:
            {
                dim3 n_blocks(1, 1, 1);
                dim3 n_threads(
                        std::min(CudaNdarray_HOST_DIMS(self)[0], NUM_VECTOR_OP_THREADS_PER_BLOCK)
                    );
                k_iAdd_3<<<n_blocks, n_threads>>>(1,
                        1, //CudaNdarray_HOST_DIMS(self)[0],
                        CudaNdarray_HOST_DIMS(self)[0],
                        CudaNdarray_DEV_DATA(self),
                        1,
                        1, //CudaNdarray_HOST_STRIDES(self)[0],
                        CudaNdarray_HOST_STRIDES(self)[0],
                        CudaNdarray_DEV_DATA(other),
                        1,
                        1, //CudaNdarray_HOST_STRIDES(other)[0],
                        CudaNdarray_HOST_STRIDES(other)[0]);
                CNDA_THREAD_SYNC;
                cudaError_t err = cudaGetLastError();
                if( cudaSuccess != err) 
                {
                    PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s.\n", "k_iAdd", cudaGetErrorString(err));
                    return NULL;
                }
                Py_INCREF(py_self);
                return py_self;
            }
        case 2:
            {
                dim3 n_blocks(1,
                        std::min(CudaNdarray_HOST_DIMS(self)[0], NUM_VECTOR_OP_BLOCKS)
                        );
                dim3 n_threads(
                        std::min(CudaNdarray_HOST_DIMS(self)[1], NUM_VECTOR_OP_THREADS_PER_BLOCK)
                    );
                k_iAdd_3<<<n_blocks, n_threads>>>(1,
                        CudaNdarray_HOST_DIMS(self)[0],
                        CudaNdarray_HOST_DIMS(self)[1],
                        CudaNdarray_DEV_DATA(self),
                        1,
                        CudaNdarray_HOST_STRIDES(self)[0],
                        CudaNdarray_HOST_STRIDES(self)[1],
                        CudaNdarray_DEV_DATA(other),
                        1,
                        CudaNdarray_HOST_STRIDES(other)[0],
                        CudaNdarray_HOST_STRIDES(other)[1]);
                CNDA_THREAD_SYNC;
                cudaError_t err = cudaGetLastError();
                if( cudaSuccess != err) 
                {
                    PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s.\n", "k_iAdd", cudaGetErrorString(err));
                    return NULL;
                }
                Py_INCREF(py_self);
                return py_self;
            }
        case 3:
            {
                dim3 n_blocks(
                        std::min(CudaNdarray_HOST_DIMS(self)[0], NUM_VECTOR_OP_BLOCKS),
                        CudaNdarray_HOST_DIMS(self)[1]
                        );
                while (n_blocks.x * n_blocks.y > NUM_VECTOR_OP_BLOCKS) n_blocks.y /= 2;
                dim3 n_threads(
                        std::min(CudaNdarray_HOST_DIMS(self)[2], NUM_VECTOR_OP_THREADS_PER_BLOCK)
                    );
                k_iAdd_3<<<n_blocks, n_threads>>>(
                        CudaNdarray_HOST_DIMS(self)[0],
                        CudaNdarray_HOST_DIMS(self)[1],
                        CudaNdarray_HOST_DIMS(self)[2],
                        CudaNdarray_DEV_DATA(self),
                        CudaNdarray_HOST_STRIDES(self)[0],
                        CudaNdarray_HOST_STRIDES(self)[1],
                        CudaNdarray_HOST_STRIDES(self)[2],
                        CudaNdarray_DEV_DATA(other),
                        CudaNdarray_HOST_STRIDES(other)[0],
                        CudaNdarray_HOST_STRIDES(other)[1],
                        CudaNdarray_HOST_STRIDES(other)[2]);
                CNDA_THREAD_SYNC;
                cudaError_t err = cudaGetLastError();
                if( cudaSuccess != err) 
                {
                    PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s.\n", "k_iAdd", cudaGetErrorString(err));
                    return NULL;
                }
                Py_INCREF(py_self);
                return py_self;
            }
        case 4:
            {
                dim3 n_blocks(
                        std::min(CudaNdarray_HOST_DIMS(self)[0], NUM_VECTOR_OP_BLOCKS),
                        CudaNdarray_HOST_DIMS(self)[1]
                        );
                while (n_blocks.x * n_blocks.y > NUM_VECTOR_OP_BLOCKS) n_blocks.y /= 2;
                dim3 n_threads(
                        std::min(CudaNdarray_HOST_DIMS(self)[2], NUM_VECTOR_OP_THREADS_PER_BLOCK)
                    );
                k_iAdd_4<<<n_blocks, n_threads>>>(
                        CudaNdarray_HOST_DIMS(self)[0],
                        CudaNdarray_HOST_DIMS(self)[1],
                        CudaNdarray_HOST_DIMS(self)[2],
                        CudaNdarray_HOST_DIMS(self)[3],
                        CudaNdarray_DEV_DATA(self),
                        CudaNdarray_HOST_STRIDES(self)[0],
                        CudaNdarray_HOST_STRIDES(self)[1],
                        CudaNdarray_HOST_STRIDES(self)[2],
                        CudaNdarray_HOST_STRIDES(self)[3],
                        CudaNdarray_DEV_DATA(other),
                        CudaNdarray_HOST_STRIDES(other)[0],
                        CudaNdarray_HOST_STRIDES(other)[1],
                        CudaNdarray_HOST_STRIDES(other)[2],
                        CudaNdarray_HOST_STRIDES(other)[3]);
                CNDA_THREAD_SYNC;
                cudaError_t err = cudaGetLastError();
                if( cudaSuccess != err) 
                {
                    PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s.\n", "k_iAdd", cudaGetErrorString(err));
                    return NULL;
                }
                Py_INCREF(py_self);
                return py_self;
            }
    }

    PyErr_Format(PyExc_NotImplementedError, "inplace_add w nd=%i\n", self->nd);
    return NULL;
}

static PyNumberMethods CudaNdarrayNumberMethods =
{
     (binaryfunc)CudaNdarray_add,  //binaryfunc nb_add;
     0,  //binaryfunc nb_subtract;
     0,  //binaryfunc nb_multiply;
     0,  //binaryfunc nb_divide;
     0,  //binaryfunc nb_remainder;
     0,  //binaryfunc nb_divmod;
     0,  //ternaryfunc nb_power;
     0,  //unaryfunc nb_negative;
     0,  //unaryfunc nb_positive;
     0,  //unaryfunc nb_absolute;
     0,  //inquiry nb_nonzero;       /* Used by PyObject_IsTrue */
     0,  //unaryfunc nb_invert;
     0,  //binaryfunc nb_lshift;
     0,  //binaryfunc nb_rshift;
     0,  //binaryfunc nb_and;
     0,  //binaryfunc nb_xor;
     0,  //binaryfunc nb_or;
     0,  //coercion nb_coerce;       /* Used by the coerce() function */
     0,  //unaryfunc nb_int;
     0,  //unaryfunc nb_long;
     0,  //unaryfunc nb_float;
     0,  //unaryfunc nb_oct;
     0,  //unaryfunc nb_hex;

     /* Added in release 2.0 */
     (binaryfunc)CudaNdarray_inplace_add,  //binaryfunc nb_inplace_add;
     0,  //binaryfunc nb_inplace_subtract;
     0,  //binaryfunc nb_inplace_multiply;
     0,  //binaryfunc nb_inplace_divide;
     0,  //binaryfunc nb_inplace_remainder;
     0,  //ternaryfunc nb_inplace_power;
     0,  //binaryfunc nb_inplace_lshift;
     0,  //binaryfunc nb_inplace_rshift;
     0,  //binaryfunc nb_inplace_and;
     0,  //binaryfunc nb_inplace_xor;
     0,  //binaryfunc nb_inplace_or;

     /* Added in release 2.2 */
     0,  //binaryfunc nb_floor_divide;
     0,  //binaryfunc nb_true_divide;
     0,  //binaryfunc nb_inplace_floor_divide;
     0,  //binaryfunc nb_inplace_true_divide;

#if PY_MINOR_VERSION > 4
     /* Added in release 2.5 */
     0  //unaryfunc nb_index;
#endif
};


/////////////////////
// Mapping protocol
/////////////////////

static Py_ssize_t 
CudaNdarray_len(PyObject * py_self)
{
    CudaNdarray * self = (CudaNdarray*) py_self;
    if (self->nd <= 0)
    {
        return (Py_ssize_t) 0;
    }
    else
    {
        return (Py_ssize_t) CudaNdarray_HOST_DIMS(self)[0];
    }
}

static PyObject *
CudaNdarray_Subscript(PyObject * py_self, PyObject * key)
{
    int verbose = 0;
    if (verbose) fprintf(stderr, "Subscript .... \n");
    CudaNdarray * self = (CudaNdarray*) py_self;
    PyObject * py_rval = NULL;
    CudaNdarray * rval = NULL;

    if (key == Py_Ellipsis)
    {
        Py_INCREF(py_self);
        return py_self;
    }
    else if (PyInt_Check(key)) //INDEXING BY INTEGER
    {
        if (self->nd == 0)
        {
            PyErr_SetString(PyExc_NotImplementedError, "index into 0-d array");
            return NULL;
        }

        int d_idx = PyInt_AsLong(key);
        int d_dim = CudaNdarray_HOST_DIMS(self)[0];
        int offset = 0;

        if ((d_idx >= 0) && (d_idx < d_dim))
        {
            //normal indexing
            offset += d_idx * CudaNdarray_HOST_STRIDES(self)[0];
        }
        else if ((d_idx < 0) && (d_idx >= -d_dim))
        {
            //end-based indexing
            offset += (d_dim - d_idx) * CudaNdarray_HOST_STRIDES(self)[0];
        }
        else
        {
            PyErr_SetString(PyExc_IndexError, "index out of bounds");
            Py_DECREF(rval);
            return NULL;
        }

        //allocate our subtensor view
        py_rval = CudaNdarray_new_nd(self->nd - 1);
        rval = (CudaNdarray*) py_rval;
        if (!rval) return NULL;
        assert (0 == rval->data_allocated);

        //initialize the view's data pointer to our own.
        if (CudaNdarray_set_device_data(rval, CudaNdarray_DEV_DATA(self) + offset, self))
        {
            Py_DECREF(rval);
            return NULL;
        }
        for (int d = 1; d < self->nd; ++d)
        {
            CudaNdarray_set_stride(rval, d-1, CudaNdarray_HOST_STRIDES(self)[d]);
            CudaNdarray_set_dim(rval, d-1, CudaNdarray_HOST_DIMS(self)[d]);
        }
    }
    else if (PySlice_Check(key)) //INDEXING BY SLICE
    {
        if (self->nd == 0)
        {
            PyErr_SetString(PyExc_NotImplementedError, "index into 0-d array");
            return NULL;
        }

        int d_dim = CudaNdarray_HOST_DIMS(self)[0];
        Py_ssize_t start, stop, step, slen;
        if (PySlice_GetIndicesEx((PySliceObject*)key, d_dim, &start, &stop, &step, &slen))
        {
            return NULL;
        }
        if (verbose)
        {
            std::cerr << "start " << start << "\n";
            std::cerr << "stop " << stop << "\n";
            std::cerr << "step " << step << "\n";
            std::cerr << "slen " << slen << "\n";
        }

        //allocate our subtensor view
        py_rval = CudaNdarray_new_nd(self->nd);
        rval = (CudaNdarray*) py_rval;
        if (!rval) return NULL;
        assert (0 == rval->data_allocated);


        //initialize the view's data pointer to our own.
        if (CudaNdarray_set_device_data(rval,
                    CudaNdarray_DEV_DATA(self) + start * CudaNdarray_HOST_STRIDES(self)[0],
                    self))
        {
            Py_DECREF(rval);
            return NULL;
        }
        //initialize dimension 0 of rval
        CudaNdarray_set_stride(rval, 0, step * CudaNdarray_HOST_STRIDES(self)[0]);
        CudaNdarray_set_dim(rval, 0, slen);
        if (verbose) std::cerr << "rval stride " << CudaNdarray_HOST_STRIDES(rval)[0] << "\n";
        // initialize dimensions > 0 of rval
        for (int d = 1; d < self->nd; ++d)
        {
            CudaNdarray_set_stride(rval, d, CudaNdarray_HOST_STRIDES(self)[d]);
            CudaNdarray_set_dim(rval, d, CudaNdarray_HOST_DIMS(self)[d]);
        }
    }
    else if (PyTuple_Check(key)) //INDEXING BY TUPLE
    {
        //elements of the tuple can be either integers or slices
        //the dimensionality of the view we will return is diminished for each slice in the tuple
        
        if (PyTuple_Size(key) > self->nd)
        {
            PyErr_SetString(PyExc_IndexError, "index error");
            return NULL;
        }

        //calculate the number of dimensions in the return value
        int rval_nd = self->nd;
        for (int d = 0; d < PyTuple_Size(key); ++d)
        {
            rval_nd -= PyInt_Check(PyTuple_GetItem(key, d));
        }

        //allocate our subtensor view
        py_rval = CudaNdarray_new_nd(rval_nd);
        rval = (CudaNdarray*) py_rval;
        if (!rval) return NULL;
        assert (0 == rval->data_allocated);

        //initialize the view's data pointer to our own.
        if (CudaNdarray_set_device_data(rval, CudaNdarray_DEV_DATA(self), self))
        {
            Py_DECREF(rval);
            return NULL;
        }

        // rval_d will refer to the current dimension in the rval.  
        // It will not be incremented for integer keys, but will be incremented for slice
        // keys
        int rval_d = 0;

        for (int d = 0; d < self->nd; ++d)
        {
            // keys can be shorter than self->nd.
            // when that happens, it means that the remaining dimensions are "full slices"
            if (d >=PyTuple_Size(key)) 
            {
                CudaNdarray_set_stride(rval, rval_d, CudaNdarray_HOST_STRIDES(self)[d]);
                CudaNdarray_set_dim(rval, rval_d, CudaNdarray_HOST_DIMS(self)[d]);
                ++rval_d;
            }
            else
            {
                PyObject * key_d = PyTuple_GetItem(key, d);

                if (PySlice_Check(key_d))
                {
                    Py_ssize_t start, stop, step, slen;
                    if (PySlice_GetIndicesEx((PySliceObject*)key_d, CudaNdarray_HOST_DIMS(self)[d], &start, &stop, &step, &slen))
                    {
                        Py_DECREF(rval);
                        return NULL;
                    }
                    rval->devdata += start * CudaNdarray_HOST_STRIDES(self)[d];
                    CudaNdarray_set_stride(rval, rval_d, step * CudaNdarray_HOST_STRIDES(self)[d]);
                    CudaNdarray_set_dim(rval, rval_d, slen);
                    if (0)
                    {
                        std::cerr << "start " << start << "\n";
                        std::cerr << "stop " << stop << "\n";
                        std::cerr << "step " << step << "\n";
                        std::cerr << "slen " << slen << "\n";
                    }
                    ++rval_d;
                }
                else if (PyInt_Check(key_d))
                {
                    int d_idx = PyInt_AsLong(key_d);
                    int d_dim = CudaNdarray_HOST_DIMS(self)[d];

                    if ((d_idx >= 0) && (d_idx < d_dim))
                    {
                        //normal indexing
                        rval->devdata += d_idx * CudaNdarray_HOST_STRIDES(self)[d];
                    }
                    else if ((d_idx < 0) && (d_idx >= -d_dim))
                    {
                        //end-based indexing
                        rval->devdata += (d_dim + d_idx) * CudaNdarray_HOST_STRIDES(self)[d];
                    }
                    else
                    {
                        PyErr_SetString(PyExc_IndexError, "index out of bounds");
                        Py_DECREF(rval);
                        return NULL;
                    }
                }
                else
                {
                    PyErr_SetString(PyExc_IndexError, "index must be either int or slice");
                    Py_DECREF(rval);
                    return NULL;
                }
            }
        }
    }
    else
    {
        PyErr_SetString(PyExc_NotImplementedError, "Unknown key type");
        return NULL;
    }
    if (py_rval)
    {
        if (verbose) fprint_CudaNdarray(stderr, self);
        if (verbose) fprint_CudaNdarray(stderr, rval);
    }
    return py_rval;
}

PyMappingMethods CudaNdarrayMappingMethods = {
    CudaNdarray_len, //lenfunc mp_length;
    CudaNdarray_Subscript, //binaryfunc mp_subscript;
    0, //objobjargproc mp_ass_subscript;
};

////////////////////
//
////////////////////

static PyObject *
CudaNdarray_get_shape(CudaNdarray *self, void *closure)
{
    if (self->nd < 0)
    {
        PyErr_SetString(PyExc_ValueError, "CudaNdarray not initialized");
        return NULL;
    }
    PyObject * rval = PyTuple_New(self->nd);
    for (int i = 0; i < self->nd; ++i)
    {
        if (!rval || PyTuple_SetItem(rval, i, PyInt_FromLong(CudaNdarray_HOST_DIMS(self)[i])))
        {
            Py_XDECREF(rval);
            return NULL;
        }

    }
    return rval;
}

static int
CudaNdarray_set_shape(CudaNdarray *self, PyObject *value, void *closure)
{
    PyErr_SetString(PyExc_NotImplementedError, "TODO: call reshape");
    return -1;
}

static PyObject *
CudaNdarray_get_strides(CudaNdarray *self, void *closure)
{
    if (self->nd < 0)
    {
        PyErr_SetString(PyExc_ValueError, "CudaNdarray not initialized");
        return NULL;
    }
    PyObject * rval = PyTuple_New(self->nd);
    for (int i = 0; i < self->nd; ++i)
    {
        if (!rval || PyTuple_SetItem(rval, i, PyInt_FromLong(CudaNdarray_HOST_STRIDES(self)[i])))
        {
            Py_XDECREF(rval);
            return NULL;
        }

    }
    return rval;
}

static int
CudaNdarray_set_strides(CudaNdarray *self, PyObject *value, void *closure)
{
    PyErr_SetString(PyExc_NotImplementedError, "");
    return -1;
}

static PyObject *
CudaNdarray_get_dev_data(CudaNdarray *self, void *closure)
{
    float * p =  CudaNdarray_DEV_DATA(self);
    //printf("get_dev_data %p %li \n", p, (long int)p );
    return PyInt_FromLong((long int) CudaNdarray_DEV_DATA(self));
}

static int
CudaNdarray_set_dev_data(CudaNdarray *self, PyObject *value, void *closure)
{
    long int newdevdata = PyInt_AsLong(value);
    //printf("set_dev_data %p %li \n",(float*)newdevdata ,newdevdata);
    if (PyErr_Occurred())
    {
        return -1;
    }
    return  CudaNdarray_set_device_data(self, (float*)newdevdata, (CudaNdarray*)self->base);
}

static PyGetSetDef CudaNdarray_getset[] = {
    {"shape", 
        (getter)CudaNdarray_get_shape, 
        (setter)CudaNdarray_set_shape, 
        "shape of this ndarray (tuple)",
        NULL},
    {"_strides", 
        (getter)CudaNdarray_get_strides, 
        (setter)CudaNdarray_set_strides, 
        "data pointer strides (in elements)",
        NULL},
    {"_dev_data", 
        (getter)CudaNdarray_get_dev_data, 
        (setter)CudaNdarray_set_dev_data,
        "device data pointer",
        NULL},
    {NULL, NULL, NULL, NULL}  /* Sentinel */
};



static PyTypeObject CudaNdarrayType = 
{
    PyObject_HEAD_INIT(NULL)
    0,                         /*ob_size*/
    "CudaNdarray",             /*tp_name*/
    sizeof(CudaNdarray),       /*tp_basicsize*/
    0,                         /*tp_itemsize*/
    (destructor)CudaNdarray_dealloc, /*tp_dealloc*/
    0,                         /*tp_print*/
    0,                         /*tp_getattr*/
    0,                         /*tp_setattr*/
    0,                         /*tp_compare*/
    0,                         /*tp_repr*/
    &CudaNdarrayNumberMethods, /*tp_as_number*/
    0,                         /*tp_as_sequence*/
    &CudaNdarrayMappingMethods,/*tp_as_mapping*/
    0,                         /*tp_hash */
    0,                         /*tp_call*/
    0,                         /*tp_str*/
    0,                         /*tp_getattro*/
    0,                         /*tp_setattro*/
    0,                         /*tp_as_buffer*/
    Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE | Py_TPFLAGS_CHECKTYPES, /*tp_flags*/
    "CudaNdarray objects",     /* tp_doc */
    0,                         /* tp_traverse */
    0,                         /* tp_clear */
    0,                         /* tp_richcompare */
    0,                         /* tp_weaklistoffset */
    0,                         /* tp_iter */
    0,                         /* tp_iternext */
    CudaNdarray_methods,       /* tp_methods */
    CudaNdarray_members,       /* tp_members */
    CudaNdarray_getset,        /* tp_getset */
    0,                         /* tp_base */
    0,                         /* tp_dict */
    0,                         /* tp_descr_get */
    0,                         /* tp_descr_set */
    0,                         /* tp_dictoffset */
    (initproc)CudaNdarray_init,/* tp_init */
    0,                         /* tp_alloc */
    CudaNdarray_new,           /* tp_new */
};

PyObject *
CudaNdarray_gpu_init(PyObject* _unsed, PyObject * args)
{
  int card_nb=0;

  if (! PyArg_ParseTuple(args, "|i", &card_nb))
    return NULL; 

  int deviceCount;

  cudaError err = cudaGetDeviceCount(&deviceCount);
  if( cudaSuccess != err) {
    //TODO: put this as a warning and let theano continue on the cpu...
    PyErr_Format(PyExc_RuntimeError, "ERROR: Not able to get the number of gpu available.");
    return NULL;
  }
  if (deviceCount <= 0) {
    //TODO: put this as a warning and let theano continue on the cpu...
    PyErr_Format(PyExc_RuntimeError, "ERROR: Can't use the GPU, no devices supporting CUDA.\n");
    return NULL;
  }
  if(card_nb<0 || card_nb>(deviceCount-1)){
    PyErr_Format(PyExc_RuntimeError, "ERROR: bad device number %d. Their is only %d device available\n",
		 card_nb, deviceCount);
    return NULL;
  }

  cudaDeviceProp deviceProp;
  err=cudaGetDeviceProperties(&deviceProp, card_nb);
  if( cudaSuccess != err) {
    PyErr_Format(PyExc_RuntimeError, "ERROR: Was not able to get the property of the gpu %i.",
		 card_nb);
    exit(-1);
  }

  if(deviceProp.major == 9999 && deviceProp.minor == 9999 ){
    PyErr_Format(PyExc_RuntimeError, "WARNING: Their is no device that support CUDA.\n");
    return NULL;    
  }
  
  fprintf(stderr, "Using gpu device %d: %s\n", card_nb, deviceProp.name);

  err = cudaSetDevice(card_nb);
  if( cudaSuccess != err) {
    PyErr_Format(PyExc_RuntimeError, "ERROR: Was not able to set the device. %s\n", cudaGetErrorString(err));
    return NULL;
  }

  Py_INCREF(Py_None);
  return Py_None;
}

PyObject *
CudaNdarray_Dot(PyObject* _unsed, PyObject * args)
{
    PyObject *l=NULL;
    PyObject *r=NULL;
    PyObject * rval = NULL;

    if (! PyArg_ParseTuple(args, "OO", &l, &r))
        return NULL; 

    if (!CudaNdarray_Check(l) || !CudaNdarray_Check(r))
    {
        PyErr_SetString(PyExc_TypeError, "CudaNdarray arguments required ");
        goto CudaNdarray_dot_fail;
    }
    if (((CudaNdarray*)l)->nd != 2)
    {
        PyErr_SetString(PyExc_TypeError, "need 2d CudaNdarray arg for now");
        goto CudaNdarray_dot_fail;
    }
    if (((CudaNdarray*)r)->nd != 2)
    {
        PyErr_SetString(PyExc_TypeError, "need 2d CudaNdarray arg for now");
        goto CudaNdarray_dot_fail;
    }
    rval = CudaNdarray_new_null();
    if (!rval)
    {
        goto CudaNdarray_dot_fail;
    }
    int dims[2];
    dims[0] = CudaNdarray_HOST_DIMS((CudaNdarray*)l)[0];
    dims[1] = CudaNdarray_HOST_DIMS((CudaNdarray*)r)[1];
    if (CudaNdarray_alloc_contiguous((CudaNdarray*)rval, 2, dims))
    {
        goto CudaNdarray_dot_fail;
    }
    if (CudaNdarray_gemm(1.0, (CudaNdarray*)l, (CudaNdarray*)r, 0.0, (CudaNdarray*)rval))
    {
        goto CudaNdarray_dot_fail;
    }

    return rval;

    CudaNdarray_dot_fail:
    Py_XDECREF(rval);
    return NULL;
}

static PyObject * 
filter(PyObject* __unsed_self, PyObject *args) // args = (data, broadcastable, strict)
{
    PyObject *py_data=NULL;
    PyArrayObject * data = NULL;
    int strict = 0;
    PyObject * broadcastable=NULL;

    if (!PyArg_ParseTuple(args, "OOi", &py_data, &broadcastable, &strict)) return NULL;

    if (!PyTuple_Check(broadcastable)){
        PyErr_SetString(PyExc_TypeError, "broadcastable arg should be a tuple of int.");
        return NULL;
    }
    Py_INCREF(py_data);
    Py_INCREF(broadcastable);

    CudaNdarray * cnda = (CudaNdarray*)py_data;

    if (strict or CudaNdarray_Check(py_data))
    {
        //TODO: support non-strict "casting" from a vt to the broadcastable/type/size that we need.
        if (!CudaNdarray_Check(py_data)) 
        {
            Py_DECREF(py_data);
            Py_DECREF(broadcastable);
            PyErr_SetString(PyExc_TypeError, "strict mode requires CudaNdarray");
            return NULL;
        }
        if (cnda->nd != PyTuple_Size(broadcastable))
        {
            Py_DECREF(py_data);
            Py_DECREF(broadcastable);
            PyErr_Format(PyExc_TypeError, "Wrong rank: %i vs %li", cnda->nd, (long)PyTuple_Size(broadcastable));
            return NULL;
        }
        for (int i = 0; i < cnda->nd; ++i)
        {
            if ((CudaNdarray_HOST_DIMS(cnda)[i] > 1) and PyInt_AsLong(PyTuple_GetItem(broadcastable, Py_ssize_t(i))))
            {
                PyErr_Format(PyExc_TypeError, "Non-unit size in broadcastable vt dimension %i", i);
                Py_DECREF(py_data);
                Py_DECREF(broadcastable);
                return NULL;
            }
        }
        Py_DECREF(broadcastable);
        return py_data;
    }
    else
    {
        data = (PyArrayObject*)PyArray_FromObject(py_data, REAL_TYPENUM, PyTuple_Size(broadcastable), PyTuple_Size(broadcastable));
        if (!data)
        {
            //err message already defined
            Py_DECREF(py_data);
            Py_DECREF(broadcastable);
            return NULL;
        }
        for (int i = 0; i < data->nd; ++i)
        {
            if ((data->dimensions[i] > 1) and PyInt_AsLong(PyTuple_GetItem(broadcastable, Py_ssize_t(i))))
            {
                PyErr_Format(PyExc_TypeError, "Non-unit size in broadcastable dimension %i", i);
                Py_DECREF(data);
                Py_DECREF(py_data);
                Py_DECREF(broadcastable);
                return NULL;
            }
        }
        CudaNdarray * rval = (CudaNdarray*) CudaNdarray_new_null();
        if (CudaNdarray_CopyFromArray(rval, data))
        {
            Py_DECREF(rval);
            rval = NULL;
        }
        Py_DECREF(data);
        Py_DECREF(py_data);
        Py_DECREF(broadcastable);
        return (PyObject*)rval;
    }
}

static PyMethodDef module_methods[] = {
    {"dot", CudaNdarray_Dot, METH_VARARGS, "Returns the matrix product of two CudaNdarray arguments."},
    {"gpu_init", CudaNdarray_gpu_init, METH_VARARGS, "Allow to select the gpu card to use."},
    {"filter", filter, METH_VARARGS, "no doc!"},    
    {NULL, NULL, NULL, NULL}  /* Sentinel */
};

#ifndef PyMODINIT_FUNC  /* declarations for DLL import/export */
#define PyMODINIT_FUNC void
#endif
PyMODINIT_FUNC
initcuda_ndarray(void) 
{
    import_array();

    PyObject* m;

    if (PyType_Ready(&CudaNdarrayType) < 0)
        return;

    m = Py_InitModule3("cuda_ndarray", module_methods,
                       "Example module that creates an extension type.");

    if (m == NULL)
        return;

    Py_INCREF(&CudaNdarrayType);
    PyModule_AddObject(m, "CudaNdarray", (PyObject *)&CudaNdarrayType);

    //    cublasInit();
    if (0&&CUBLAS_STATUS_SUCCESS != cublasGetError())
    {
        std::cerr << "WARNING: initcuda_ndarray: error initializing device\n";
    }
    if (0) //TODO: is this necessary?
    {
        int deviceId = 0; // TODO: what number goes here?
        cudaSetDevice(deviceId);
        cudaError_t err = cudaGetLastError();
        if( cudaSuccess != err) 
        {
            std::cerr << "Error in SetDevice:" << cudaGetErrorString(err) << "\n";
        }                         
    }
}


//////////////////////////////////////
//
// C API FOR CudaNdarray
//
//////////////////////////////////////

int 
CudaNdarray_Check(const PyObject * ob)
{
    //TODO: doesn't work with inheritance
    return CudaNdarray_CheckExact(ob);
}
int 
CudaNdarray_CheckExact(const PyObject * ob)
{
    return ((ob->ob_type == &CudaNdarrayType) ? 1 : 0);
}

PyObject * 
CudaNdarray_New(int nd)
{
    CudaNdarray *self = (CudaNdarray *)CudaNdarrayType.tp_alloc(&CudaNdarrayType, 0);
    if (self == NULL) 
    {
        PyErr_SetString(PyExc_RuntimeError, "CudaNdarray_new_null failed to allocate self");
        return NULL;
    }
    CudaNdarray_null_init(self);
    
    if (nd == 0)
    {
        self->nd = 0;
    }
    else if (nd > 0)
    {
        if (CudaNdarray_set_nd(self, nd))
        {
            Py_DECREF(self);
            return NULL;
        }
    }
    return (PyObject *)self;
}



//////////////////////////////
//
// Published helper functions
//
//////////////////////////////

int 
cublas_init() 
{
    cublasInit();
    if (CUBLAS_STATUS_SUCCESS != cublasGetError())
    {
        PyErr_SetString(PyExc_RuntimeError, "error initializing device");
        return -1;
    }
    return 0;
}
int 
cublas_shutdown() 
{
    cublasShutdown();
    if (CUBLAS_STATUS_SUCCESS != cublasGetError())
    {
        PyErr_SetString(PyExc_RuntimeError, "error shutting down device");
        return -1;
    }
    return 0;
}

int 
CudaNdarray_CopyFromArray(CudaNdarray * self, PyArrayObject*obj)
{
    int err = CudaNdarray_alloc_contiguous(self, obj->nd, obj->dimensions);
    if (err) {
        return err;
    }

    int typenum = PyArray_TYPE(obj);
    if (typenum != REAL_TYPENUM)
    {
        PyErr_SetString(PyExc_TypeError, "can only copy from float arrays");
        return -1;
    }
    assert( 4 ==  PyArray_ITEMSIZE(obj));
    PyObject * py_src = PyArray_ContiguousFromAny((PyObject*)obj, typenum, self->nd, self->nd);
    if (!py_src) {
        return -1;
    }
    cublasSetVector(PyArray_SIZE(py_src),
            sizeof(real), 
            PyArray_DATA(py_src), 1,
            self->devdata, 1);
    CNDA_THREAD_SYNC;
    if (CUBLAS_STATUS_SUCCESS != cublasGetError())
    {
        PyErr_SetString(PyExc_RuntimeError, "error copying data to device memory");
        Py_DECREF(py_src);
        return -1;
    }
    Py_DECREF(py_src);
    return 0;
}
bool 
CudaNdarray_is_c_contiguous(const CudaNdarray * self)
{
    bool c_contiguous = true;
    int size = 1;
    for (int i = self->nd-1; (i >= 0) and c_contiguous; --i)
    {
        if (CudaNdarray_HOST_DIMS(self)[i] == 1)
            continue;
        //std::cerr << i << " "<< str << "BBBB\n";
        if (CudaNdarray_HOST_STRIDES(self)[i] != size)
        {
            c_contiguous = false;
        }
        size = size * CudaNdarray_HOST_DIMS(self)[i];
    }
    return c_contiguous;
}
PyObject *
CudaNdarray_new_null()
{
    //TODO: this function is deprecated... do not use. Consider removing.
    return CudaNdarray_New(-1);
}
PyObject *
CudaNdarray_new_nd(int nd)
{
    CudaNdarray * rval = (CudaNdarray*) CudaNdarray_new_null();
    if (!rval || CudaNdarray_set_nd(rval, nd))
    {
        Py_XDECREF(rval);
        rval = NULL;
    }
    return (PyObject *) rval;
}

int CudaNdarray_set_device_data(CudaNdarray * self, float * data, CudaNdarray * base)
{
    if (self->data_allocated)
    {
        assert(self->devdata);
        cublasFree(self->devdata);
        if (CUBLAS_STATUS_SUCCESS != cublasGetError())
        {
            PyErr_SetString(PyExc_MemoryError, "error freeing device memory");
            self->devdata = NULL;
            self->data_allocated = 0;
            return -1;
        }
    }
    //N.B. XDECREF and XINCREF are no-ops for NULL pointers
    if (self->base != (PyObject*)base)
    {
        Py_XDECREF(self->base);
        self->base = (PyObject*)base;
        Py_XINCREF(self->base);
    }
    self->data_allocated = 0;
    self->devdata = data;
    return 0;
}

static __global__ void k_copy_1d(const int N, const float * x, const int sx, float * y, const int sy)
{
    for (int i = threadIdx.x + blockIdx.x * blockDim.x; i < N; i += gridDim.x*blockDim.x)
    {
        y[i*sy] = x[i*sx];
    }
}

//copy from other into self
int CudaNdarray_CopyFromCudaNdarray(CudaNdarray * self, CudaNdarray * other)
{
    int verbose = 0;
    //standard elemwise size checks
    if (self->nd == -1)
    {
        PyErr_SetString(PyExc_TypeError, "can't copy into un-initialized CudaNdarray");
        return -1;
    }
    if (self->nd != other->nd)
    {
        PyErr_SetString(PyExc_TypeError, "need same number of dims");
        return -1;
    }
    //standard elemwise dim checks (also compute total size)
    unsigned int size = 1;
    for (int i = 0; i< self->nd; ++i)
    {
        if (CudaNdarray_HOST_DIMS(self)[i] != CudaNdarray_HOST_DIMS(other)[i])
        {
            PyErr_SetString(PyExc_TypeError, "need same dimensions");
            return -1;
        }
        size *= (unsigned int) CudaNdarray_HOST_DIMS(self)[i];
    }
    if (CudaNdarray_is_c_contiguous(self) && CudaNdarray_is_c_contiguous(other))
    {
        cublasScopy(size, CudaNdarray_DEV_DATA(other), 1, CudaNdarray_DEV_DATA(self), 1);
        if (CUBLAS_STATUS_SUCCESS != cublasGetError())
        {
            PyErr_SetString(PyExc_RuntimeError, "Error copying memory");
            return -1;
        }
        return 0;
    }
    //TODO: rewrite these copy operations to be more efficient
    //      See, for example the transpose example in the cuda_sdk.
    switch (self->nd)
    {
        case 0: // scalar
            {
                assert (size==1);
                cublasScopy(1, CudaNdarray_DEV_DATA(other), 1, CudaNdarray_DEV_DATA(self), 1);
                CNDA_THREAD_SYNC;
                if (CUBLAS_STATUS_SUCCESS != cublasGetError())
                {
                    PyErr_SetString(PyExc_RuntimeError, "Error copying memory");
                    return -1;
                }
            }; break;
        case 1: // vector
            {
                if (verbose) fprintf(stderr, "Copying non-contiguous vector\n");
                if (verbose) fprint_CudaNdarray(stderr, other);
                unsigned int n_blocks = std::min(size, (unsigned int)NUM_VECTOR_OP_BLOCKS);
                unsigned int n_threads = std::min(ceil_intdiv(size, n_blocks), (unsigned int)NUM_VECTOR_OP_THREADS_PER_BLOCK);
                k_copy_1d<<<n_blocks, n_threads>>>(size,
                        CudaNdarray_DEV_DATA(other), CudaNdarray_HOST_STRIDES(other)[0],
                        CudaNdarray_DEV_DATA(self), CudaNdarray_HOST_STRIDES(self)[0]);
                CNDA_THREAD_SYNC;
                cudaError_t err = cudaGetLastError();
                if( cudaSuccess != err) 
                {
                    PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s. (n_blocks=%i, n_threads_per_block=%i)\n", "k_copy_1d", cudaGetErrorString(err), n_blocks, n_threads);
                    return -1;
                }                         
            }; break;
        default:
            {
                assert (cudaSuccess == cudaGetLastError());
                // call worker routine
                unsigned int n_blocks = std::min(size, (unsigned int)NUM_VECTOR_OP_BLOCKS);
                unsigned int threads_per_block = std::min(ceil_intdiv(size, n_blocks), (unsigned int)NUM_VECTOR_OP_THREADS_PER_BLOCK);
                //copy from other into self
                k_elemwise_unary_rowmajor_copy<<<n_blocks, threads_per_block>>>(
                        size, 
                        (unsigned int)other->nd,
                        (const int *)CudaNdarray_DEV_DIMS(other),
                        (const float*)CudaNdarray_DEV_DATA(other), (const int *)CudaNdarray_DEV_STRIDES(other),
                        CudaNdarray_DEV_DATA(self),  (const int *)CudaNdarray_DEV_STRIDES(self));
                CNDA_THREAD_SYNC;
                cudaError_t err = cudaGetLastError();
                if( cudaSuccess != err) 
                {
                    //fprint_CudaNdarray(stderr, self);
                    //fprint_CudaNdarray(stderr, other);
                    PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s. (n_blocks=%i, n_threads_per_block=%i)\n", "k_elemwise_unary_rowmajor_copy", cudaGetErrorString(err), n_blocks, threads_per_block);
                    return -1;
                }                         
            }
    };
    return 0;
}

int CudaNdarray_gemm(float alpha, const CudaNdarray * A, const CudaNdarray * B, float beta, CudaNdarray * C)
{
    if (A->nd != 2) { PyErr_SetString(PyExc_ValueError, "non-matrix arg to gemm"); return -1; }
    if (B->nd != 2) { PyErr_SetString(PyExc_ValueError, "non-matrix arg to gemm"); return -1; }
    if (C->nd != 2) { PyErr_SetString(PyExc_ValueError, "non-matrix arg to gemm"); return -1; }

    if ((CudaNdarray_HOST_DIMS(A)[1] != CudaNdarray_HOST_DIMS(B)[0])
            || (CudaNdarray_HOST_DIMS(A)[0] != CudaNdarray_HOST_DIMS(C)[0])
            || (CudaNdarray_HOST_DIMS(B)[1] != CudaNdarray_HOST_DIMS(C)[1]))
    { 
        PyErr_Format(PyExc_ValueError, "dimension mismatch in args to gemm (%i,%i)x(%i,%i)->(%i,%i)",
                CudaNdarray_HOST_DIMS(A)[0],
                CudaNdarray_HOST_DIMS(A)[1],
                CudaNdarray_HOST_DIMS(B)[0],
                CudaNdarray_HOST_DIMS(B)[1],
                CudaNdarray_HOST_DIMS(C)[0],
                CudaNdarray_HOST_DIMS(C)[1]);
        return -1; 
    }

    // a matrix has non-unit size and non-unit stride in both directions, we can't operate in-place
    // TODO: make a copy instead of returning in error
    if (((CudaNdarray_HOST_DIMS(A)[0] > 1) && (CudaNdarray_HOST_STRIDES(A)[0] != 1)) && ((CudaNdarray_HOST_DIMS(A)[1] > 1) && (CudaNdarray_HOST_STRIDES(A)[1] != 1)))
    { PyErr_SetString(PyExc_NotImplementedError, "non-unit stride in gemm arg"); return -1; }
    if (((CudaNdarray_HOST_DIMS(B)[0] > 1) && (CudaNdarray_HOST_STRIDES(B)[0] != 1)) && ((CudaNdarray_HOST_DIMS(B)[1] > 1) && (CudaNdarray_HOST_STRIDES(B)[1] != 1)))
    { PyErr_SetString(PyExc_NotImplementedError, "non-unit stride in gemm arg"); return -1; }
    if (((CudaNdarray_HOST_DIMS(C)[0] > 1) && (CudaNdarray_HOST_STRIDES(C)[0] != 1)) && ((CudaNdarray_HOST_DIMS(C)[1] > 1) && (CudaNdarray_HOST_STRIDES(C)[1] != 1)))
    { PyErr_SetString(PyExc_NotImplementedError, "non-unit stride in gemm arg"); return -1; }

    // the unit integer is divided logically into three fields of 4 bits
    // the lowermost 4 bits encode the stride pattern of the output
    // the next higher 4 bits encode the B variable (or y)
    // the next higher 4 bits encode the C variable (or x)
    //
    // the stride pattern for each input is encoded as 0 for unit stride from col to col (Row major)
    //                                                 1 for unit stride from row to row (Col major)

    // a stride of 0 implies a dimension of 1 - so we can actually define
    // a stride of 0 as a 'unit' stride because gemm will never use it.
    int unit = 0;
    if (CudaNdarray_HOST_STRIDES(A)[1] == 1 || CudaNdarray_HOST_STRIDES(A)[1] == 0) {
        unit |= (0x0 << 8);
    } else if (CudaNdarray_HOST_STRIDES(A)[0] == 1 || CudaNdarray_HOST_STRIDES(A)[0] == 0) { 
        unit |= (0x1 << 8);
    } else {
        unit |= (0x2 << 8);
    }
    if (CudaNdarray_HOST_STRIDES(B)[1] == 1 || CudaNdarray_HOST_STRIDES(B)[1] == 0) {
        unit |= (0x0 << 4);
    } else if (CudaNdarray_HOST_STRIDES(B)[0] == 1 || CudaNdarray_HOST_STRIDES(B)[0] == 0) { 
        unit |= (0x1 << 4);
    } else {
        unit |= (0x2 << 4);
    }
    if (CudaNdarray_HOST_STRIDES(C)[1] == 1 || CudaNdarray_HOST_STRIDES(C)[1] == 0) {
        unit |= (0x0 << 0);
    } else if (CudaNdarray_HOST_STRIDES(C)[0] == 1 || CudaNdarray_HOST_STRIDES(C)[0] == 0) { 
        unit |= (0x1 << 0);
    } else {
        unit |= (0x2 << 0);
    }

    // I don't know if cudablas handles negative strides
    assert (CudaNdarray_HOST_STRIDES(A)[0] >= 0) ; // for now
    assert (CudaNdarray_HOST_STRIDES(A)[1] >= 0) ; // for now
    assert (CudaNdarray_HOST_STRIDES(B)[0] >= 0) ; // for now
    assert (CudaNdarray_HOST_STRIDES(B)[1] >= 0) ; // for now
    assert (CudaNdarray_HOST_STRIDES(C)[0] >= 0) ; // for now
    assert (CudaNdarray_HOST_STRIDES(C)[1] >= 0) ; // for now

    /* create appropriate strides for malformed matrices that are row or column
     * vectors
     */
    int sa_0 = (CudaNdarray_HOST_DIMS(A)[0] > 1) ? CudaNdarray_HOST_STRIDES(A)[0] : CudaNdarray_HOST_DIMS(A)[1];
    int sa_1 = (CudaNdarray_HOST_DIMS(A)[1] > 1) ? CudaNdarray_HOST_STRIDES(A)[1] : CudaNdarray_HOST_DIMS(A)[0];
    int sb_0 = (CudaNdarray_HOST_DIMS(B)[0] > 1) ? CudaNdarray_HOST_STRIDES(B)[0] : CudaNdarray_HOST_DIMS(B)[1];
    int sb_1 = (CudaNdarray_HOST_DIMS(B)[1] > 1) ? CudaNdarray_HOST_STRIDES(B)[1] : CudaNdarray_HOST_DIMS(B)[0];
    int sc_0 = (CudaNdarray_HOST_DIMS(C)[0] > 1) ? CudaNdarray_HOST_STRIDES(C)[0] : CudaNdarray_HOST_DIMS(C)[1];
    int sc_1 = (CudaNdarray_HOST_DIMS(C)[1] > 1) ? CudaNdarray_HOST_STRIDES(C)[1] : CudaNdarray_HOST_DIMS(C)[0];

    float* a = CudaNdarray_DEV_DATA(A);
    float* b = CudaNdarray_DEV_DATA(B);
    float* c = CudaNdarray_DEV_DATA(C);
    char N = 'N';
    char T = 'T';
    //std::cerr << (unit/256) MOD 16 << (unit / 16) MOD 16 << unit MOD 16<< '\\n';
    //TODO: recognize the negative stride and make a copy of the offending argument,
    //rather than aborting
#define CHK_STRIDE_SGEMM(T0, T1, D0, D1, D2, a, x, sx, y, sy, b, z, sz) \
    if ((sx > 0) && (sy > 0) && (sz > 0)) { \
        cublasSgemm(T0, T1, D0, D1, D2, a, x, sx, y, sy, b, z, sz); \
    } else { \
        PyErr_SetString(PyExc_NotImplementedError, "negative stride to sGemm");\
        return -1; \
    } 

    switch(unit)
    {
        case 0x000: CHK_STRIDE_SGEMM(N, N, CudaNdarray_HOST_DIMS(C)[1], CudaNdarray_HOST_DIMS(C)[0], CudaNdarray_HOST_DIMS(A)[1], alpha, b, sb_0, a, sa_0, beta, c, sc_0); break;
        case 0x100: CHK_STRIDE_SGEMM(N, T, CudaNdarray_HOST_DIMS(C)[1], CudaNdarray_HOST_DIMS(C)[0], CudaNdarray_HOST_DIMS(A)[1], alpha, b, sb_0, a, sa_1, beta, c, sc_0); break;
        case 0x010: CHK_STRIDE_SGEMM(T, N, CudaNdarray_HOST_DIMS(C)[1], CudaNdarray_HOST_DIMS(C)[0], CudaNdarray_HOST_DIMS(A)[1], alpha, b, sb_1, a, sa_0, beta, c, sc_0); break;
        case 0x110: CHK_STRIDE_SGEMM(T, T, CudaNdarray_HOST_DIMS(C)[1], CudaNdarray_HOST_DIMS(C)[0], CudaNdarray_HOST_DIMS(A)[1], alpha, b, sb_1, a, sa_1, beta, c, sc_0); break;
        case 0x001: CHK_STRIDE_SGEMM(T, T, CudaNdarray_HOST_DIMS(C)[0], CudaNdarray_HOST_DIMS(C)[1], CudaNdarray_HOST_DIMS(A)[1], alpha, a, sa_0, b, sb_0, beta, c, sc_1); break;
        case 0x101: CHK_STRIDE_SGEMM(N, T, CudaNdarray_HOST_DIMS(C)[0], CudaNdarray_HOST_DIMS(C)[1], CudaNdarray_HOST_DIMS(A)[1], alpha, a, sa_1, b, sb_0, beta, c, sc_1); break;
        case 0x011: CHK_STRIDE_SGEMM(T, N, CudaNdarray_HOST_DIMS(C)[0], CudaNdarray_HOST_DIMS(C)[1], CudaNdarray_HOST_DIMS(A)[1], alpha, a, sa_0, b, sb_1, beta, c, sc_1); break;
        case 0x111: CHK_STRIDE_SGEMM(N, N, CudaNdarray_HOST_DIMS(C)[0], CudaNdarray_HOST_DIMS(C)[1], CudaNdarray_HOST_DIMS(A)[1], alpha, a, sa_1, b, sb_1, beta, c, sc_1); break;
        default: PyErr_Format(PyExc_ValueError, "some matrix has no unit stride (unit=%i)", unit);
                 return -1;
    };
    CNDA_THREAD_SYNC;
    if (CUBLAS_STATUS_SUCCESS != cublasGetError())
    {
        PyErr_SetString(PyExc_RuntimeError, "cublassGemm failed");
        return -1;
    }
    return 0;
}

/**
 *
 * Precondition:
 *  a->dim[d] == (dims_a[d]==0) ? (1 << log2_dims_a[d]) : dims_a[d]
 *  z->dim[d] == (z_str[d]==0) ? 1 : dims_a[d];
 *
 *  TODO: templatize this function to support other reductions.
 *  All that needs to change is the initial value for sum, and the reduction operator.
 */

static __global__ void kernel_reduce_sum(const unsigned int size_z,
        const unsigned int nd,
        const int * dims_a,
        const int * log2_dims_a,
        const int * a_str,
        const float * a_data,
        const int * z_str,
        float * z_data)
{
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    //structure data contains the strides and dimensions of both a and z
    // a_dim[0], a_dim[1], ... a_dim[nd-1],
    // a_log2dim[0], a_log2dim[1], ... a_log2dim[nd-1],
    // a_str[0], ... a_str[nd-1],
    // z_str[0], ... z_str[nd-1]
    extern __shared__ int structure_data[];
    for (unsigned int i = threadIdx.x; i < nd; i += blockDim.x)
    {
        structure_data[i+0*nd] = dims_a[i];
        structure_data[i+1*nd] = log2_dims_a[i];
        structure_data[i+2*nd] = a_str[i];
        structure_data[i+3*nd] = z_str[i];
    }
    dims_a = structure_data;
    log2_dims_a = structure_data + nd;
    a_str = structure_data + 2*nd;
    z_str = structure_data + 3*nd;

    __syncthreads(); //wait for all the shared structure to be loaded

    for (unsigned int i = idx; i < size_z; i += numThreads)
    {
        unsigned int ii = i;
        const float * a_data_i = a_data;
        float * z_data_i = z_data;
        unsigned int n_reduce_elements = 1;
        unsigned int n_reduce_dims = 0;
        unsigned int reduce_dim0 = nd-1;


        //In this loop, we locate the initial element of the slice that we'd like to reduce with this thread
        //  At the same time, we [re]calculate the size of that slice (n_reduce_elements)
        for (unsigned int d = 0; d < nd; ++d)
        {
            if (a_str[d] && (!z_str[d])) // this means 'd' is a dimension we are reducing over
            {
                n_reduce_elements *= dims_a[d];
                n_reduce_dims += 1;
                reduce_dim0 = (d < reduce_dim0) ? d : reduce_dim0;
            }
            else //'d' is not a dimension that we are reducing over
            {
                unsigned int pos_d;
                if (log2_dims_a[d]==-1) //TODO: when things are working, use this switch
                {
                    // this branch is not preferred, 
                    // because the manual said that integer mod and div operations are slow on gpu
                    pos_d = (ii % dims_a[d]);
                    ii = (ii / dims_a[d]);
                }
                else
                {
                    pos_d = (ii & ((1 << log2_dims_a[d])-1)); //take the lower log2_dims bits
                    ii = (ii >> log2_dims_a[d]);  //shift those lower log2_dims bits off of ii
                }
                a_data_i += pos_d * a_str[d];
                z_data_i += pos_d * z_str[d];
            }
        }
        // now we've got pointers a_data_i and z_data_i into element 0 of the slice over which we are reducing
        // do a similar loop
        
        float sum = 0.0f;
        switch(n_reduce_dims)
        {
            case 0:
                {
                    sum = a_data_i[0];
                } 
                break;
            case 1:
                {
                    const int stride = a_str[reduce_dim0];
                    const float * a_data_i_max = a_data_i + dims_a[reduce_dim0] * stride;
                    while (a_data_i != a_data_i_max)
                    {
                        sum += a_data_i[0];
                        a_data_i += stride;
                    }
                }
                break;
            case 2:
                {
                    int rd = reduce_dim0+1;
                    for (; rd < nd; ++rd)
                    {
                        if (a_str[rd] && (!z_str[rd])) // this means 'rd' is a dimension we are reducing over
                            break;
                    }
                    const int stride0 = a_str[reduce_dim0];
                    const int stride1 = a_str[rd];
                    for (int ii = 0; ii < dims_a[rd]; ++ii)
                    {
                        const float * a_data_ri = a_data_i + ii * stride1;
                        const float * a_data_ri_max = a_data_ri + dims_a[reduce_dim0] * stride0;
                        while (a_data_ri != a_data_ri_max)
                        {
                            sum += a_data_ri[0];
                            a_data_ri += stride0;
                        }
                    }
                }; 
                break;
            default:
                {
                    for (unsigned int reduce_i = 0; reduce_i < n_reduce_elements; ++reduce_i)
                    {
                        //TODO: optimize this loop to work more like theano's Elemwise.  It's serial code.
                        unsigned int reduce_ii = reduce_i;
                        const float * a_data_ri = a_data_i;

                        //This loop finds the element in the a slice to add.
                        for (unsigned int rd = reduce_dim0; rd < nd; ++rd)
                        {
                            unsigned int pos_d;
                            if (a_str[rd] && (!z_str[rd])) // this means 'd' is a dimension we are reducing over
                            {
                                if (log2_dims_a[rd]==-1)
                                {
                                    // this branch is not preferred, 
                                    // because the manual said that integer mod and div operations are slow on gpu
                                    pos_d = (reduce_ii % dims_a[rd]);
                                    reduce_ii = (reduce_ii / dims_a[rd]);
                                }
                                else
                                {
                                    pos_d = (reduce_ii & ((1 << log2_dims_a[rd])-1)); //take the lower log2_dims bits
                                    reduce_ii = (reduce_ii >> log2_dims_a[rd]);  //shift those lower log2_dims bits off of ii
                                }
                                a_data_ri += pos_d * a_str[rd];
                            }
                        }
                        sum += a_data_ri[0];
                    }
                }
        }
        z_data_i[0] = sum;
    }
}

static __global__ void kernel_reduce_sum_1011(
        const unsigned int d0,
        const unsigned int d1,
        const unsigned int d2,
        const unsigned int d3,
        const float *A, const int sA0, const int sA1, const int sA2, const int sA3,
        float * Z, const int sZ0)
{
    const int threadCount = blockDim.x * blockDim.y * blockDim.z;
    const int threadNum = threadIdx.z * blockDim.x * blockDim.y + threadIdx.y * blockDim.x + threadIdx.x;
    extern __shared__ float buf[];
    float mysum = 0.0f;

    if (warpSize != 32)
    {
        return;  //TODO: set error code
    }

    for (int i0 = threadIdx.z; i0 < d0; i0 += blockDim.z)
    {
        float Ai = A[i0 * sA0 + blockIdx.x * sA1 + threadIdx.y * sA2 + threadIdx.x * sA3];
        mysum += Ai;
    }
    buf[threadNum] = mysum;
    __syncthreads();

    // rest of function is handled by one warp
    if (threadNum < warpSize)
    {
        for (int i = threadNum + warpSize; i < threadCount; i += warpSize)
        {
            mysum += buf[i];
        }
        buf[threadNum] = mysum;
        if (threadNum < 16)
        {
            //reduce so that threadNum 0 has the sum of everything
            if(threadNum + 16 < threadCount) buf[threadNum] += buf[threadNum+16];
            if(threadNum + 8 < threadCount) buf[threadNum] += buf[threadNum+8];
            if(threadNum + 4 < threadCount) buf[threadNum] += buf[threadNum+4];
            if(threadNum + 2 < threadCount) buf[threadNum] += buf[threadNum+2];
            if(threadNum + 1 < threadCount) buf[threadNum] += buf[threadNum+1];
            if (threadNum == 0)
            {
                Z[blockIdx.x*sZ0] = buf[0];
            }
        }
    }
}
/**
 * Dimensions in which the self has size 1 and A has size > 1 are considered summing dimensions
 * Dimensions in which self has size > 1 and A has size > 1 are considered non-summing dimensions, and in this case their sizes must be equal.
 */
int 
CudaNdarray_reduce_sum(CudaNdarray * self, CudaNdarray * A)
{
    int verbose = 0;
    //check input rank
    if (self->nd != A->nd)
    {
        PyErr_Format(PyExc_TypeError, "Rank mismatch in CudaNdarray_sum: %i vs %i", self->nd, A->nd);
        return -1;
    }
    for (int i = 0; i < self->nd; ++i)
    {
        if ((CudaNdarray_HOST_DIMS(self)[i] > 1) && (CudaNdarray_HOST_DIMS(self)[i] != CudaNdarray_HOST_DIMS(A)[i]))
        {
            PyErr_Format(PyExc_TypeError, "Dimension mismatch in CudaNdarray_sum: self->dim[%i] == %i , A->dim[%i] = %i",
                    i, CudaNdarray_HOST_DIMS(self)[i], i, CudaNdarray_HOST_DIMS(A)[i]);
            return -1;
        }
    }

    int n_summations = (unsigned int)CudaNdarray_SIZE(self);
    if (verbose)
    {
        std::cerr << "reduce_sum n_summations " << n_summations  << '\n';
        std::cerr << "reduce_sum nd " << self->nd  << '\n';
        fprint_CudaNdarray(stderr, A);
        fprint_CudaNdarray(stderr, self);
    }
    if (0 && (A->nd == 4) //check to see if kernel_reduce_sum_1011 applies
            && (CudaNdarray_HOST_DIMS(self)[0] == 1)
            && (CudaNdarray_HOST_DIMS(self)[2] == 1)
            && (CudaNdarray_HOST_DIMS(self)[3] == 1)
       )
    {
        dim3 n_threads(CudaNdarray_HOST_DIMS(A)[3], CudaNdarray_HOST_DIMS(A)[2]);
        dim3 n_blocks(CudaNdarray_HOST_DIMS(A)[1]);
        while (n_threads.x * n_threads.y * n_threads.z < NUM_VECTOR_OP_THREADS_PER_BLOCK) ++n_threads.z;
        n_threads.z -= 1;
        if (n_threads.z > 64) n_threads.z = 64;
        if (n_threads.z)
        {
            if (verbose) printf("trying kernel_reduce_sum_1011\n");
            int n_shared = sizeof(float) * n_threads.x * n_threads.y * n_threads.z;
            kernel_reduce_sum_1011<<<n_blocks, n_threads, n_shared>>>(
                    CudaNdarray_HOST_DIMS(A)[0],
                    CudaNdarray_HOST_DIMS(A)[1],
                    CudaNdarray_HOST_DIMS(A)[2],
                    CudaNdarray_HOST_DIMS(A)[3],
                    CudaNdarray_DEV_DATA(A),
                    CudaNdarray_HOST_STRIDES(A)[0],
                    CudaNdarray_HOST_STRIDES(A)[1],
                    CudaNdarray_HOST_STRIDES(A)[2],
                    CudaNdarray_HOST_STRIDES(A)[3],
                    CudaNdarray_DEV_DATA(self),
                    CudaNdarray_HOST_STRIDES(self)[1]);
            CNDA_THREAD_SYNC;
            if (cudaSuccess == cudaGetLastError()) return 0;
            if (verbose) printf("failed, falling back to kernel_reduce_sum\n");
        }
    }

    int n_threads_per_block = std::min(n_summations,
            NUM_VECTOR_OP_THREADS_PER_BLOCK);
    int n_blocks = std::min(ceil_intdiv(n_summations,n_threads_per_block), 
            NUM_VECTOR_OP_BLOCKS);
    int n_structure_cache = self->nd * 4 * sizeof(int);

    if (verbose)
    {
        std::cerr << "n_blocks, n_threads_per_block " << n_blocks << ' ' << n_threads_per_block  << '\n';
    }
    assert (self->nd > 0);
    assert (self->nd == A->nd);
    kernel_reduce_sum<<<n_blocks, n_threads_per_block, n_structure_cache>>>(
            n_summations,
            self->nd,
            CudaNdarray_DEV_DIMS(A),
            CudaNdarray_DEV_LOG2DIMS(A),
            CudaNdarray_DEV_STRIDES(A),
            CudaNdarray_DEV_DATA(A),
            CudaNdarray_DEV_STRIDES(self),
            CudaNdarray_DEV_DATA(self));
    CNDA_THREAD_SYNC;
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) 
    {
        PyErr_Format(PyExc_RuntimeError, "Cuda error: %s: %s.\n", "kernel_reduce_sum", cudaGetErrorString(err));
        return -1;
    }
    return 0;
}
int 
CudaNdarray_reduce_prod(CudaNdarray * self, const CudaNdarray * A)
{
    PyErr_SetString(PyExc_NotImplementedError, "");
    return -1;
}
int 
CudaNdarray_reduce_min(CudaNdarray * self, const CudaNdarray * A)
{
    PyErr_SetString(PyExc_NotImplementedError, "");
    return -1;
}
int 
CudaNdarray_reduce_max(CudaNdarray * self, const CudaNdarray * A)
{
    PyErr_SetString(PyExc_NotImplementedError, "");
    return -1;
}

/**
 *
 *  pattern is a permutation of [0, 1, ... self->nd-1] with the following twists:
 *  - an element 'd' of the permutation can be dropped if CudaNdarray_HOST_DIMS(self)[d] == 1
 *  - any number of '-1' elements can be in the pattern, and they will cause new ranks (with dim==1) to be inserted.
 *
 *  For example, if CudaNdarray_HOST_DIMS(self) == [4, 5, 1, 6], and pattern = [0,3,-1,-1, 1], then CudaNdarray_HOST_DIMS(self) would be modified to become:
 *     [4, 6, 1, 1, 5] (we dropped the original dim[2]==1, and inserted two singleton dimensions with the -1s.
 */
int 
CudaNdarray_dimshuffle(CudaNdarray * self, unsigned int len, const int * pattern)
{
    //TODO: pass a workspace pointer to avoid the internal malloc
    int * newdims = (int *)malloc(sizeof(int) * (len + len + self->nd)); //we tack on the taken buffer here for speed of not having to malloc twice.
    int * newstrides = newdims + len;
    int * dims_taken = newstrides + len;
    if (!newdims)
    {
        PyErr_SetString(PyExc_MemoryError, "CudaNdarray_dimshuffle: Failed to allocate temporary space");
        return -1;
    }
    for (int i = 0; i < self->nd; ++i)
    {
        dims_taken[i] = 0;
    }
    for (int i = 0; i < len; ++i)
    {
        if (pattern[i] < 0)
        {
            newdims[i] = 1;
            newstrides[i] = 0;
        }
        else
        {
            if ((dims_taken[pattern[i]]) or (pattern[i]>= self->nd))
            {
                PyErr_SetString(PyExc_ValueError, "invalid pattern for Cudandarray_dimshuffle");
                free(newdims);
                return -1;
            }
            newdims[i] = CudaNdarray_HOST_DIMS(self)[pattern[i]];
            newstrides[i] = CudaNdarray_HOST_STRIDES(self)[pattern[i]];
            dims_taken[pattern[i]] = 1;
        }
    }
    //swap this structure in for the one in self, and sync to the card
    if (CudaNdarray_set_nd(self, len))
    {
        free(newdims);
        return -1;
    }
    for (int i = 0; i < len; ++i)
    {
        CudaNdarray_set_dim(self, i, newdims[i]);
        CudaNdarray_set_stride(self, i, newstrides[i]);
    }
    if (cnda_copy_structure_to_device(self))
    {
        free(newdims);
        return -1;
    }
    free(newdims);
    return 0;
}
