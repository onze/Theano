"""
Tests of printing functionality
"""
import logging
import StringIO

import theano
import theano.tensor as tensor

from theano.printing import min_informative_str


def test_pydotprint_cond_highlight():
    """
    This is a REALLY PARTIAL TEST.

    I did them to help debug stuff.
    """

    x = tensor.dvector()
    f = theano.function([x], x*2)
    f([1,2,3,4])

    s = StringIO.StringIO()
    new_handler = logging.StreamHandler(s)
    new_handler.setLevel(logging.DEBUG)
    orig_handler = theano.logging_default_handler

    theano.theano_logger.removeHandler(orig_handler)
    theano.theano_logger.addHandler(new_handler)
    try:
        theano.printing.pydotprint(f, cond_highlight = True)
    finally:
        theano.theano_logger.addHandler(orig_handler)
        theano.theano_logger.removeHandler(new_handler)

    assert s.getvalue() == 'pydotprint: cond_highlight is set but there is no IfElse node in the graph\n'


def test_min_informative_str():
    """ evaluates a reference output to make sure the
        min_informative_str function works as intended """

    A = tensor.matrix(name = 'A')
    B = tensor.matrix(name = 'B')
    C = A + B
    C.name = 'C'
    D = tensor.matrix(name = 'D')
    E = tensor.matrix(name = 'E')

    F = D + E
    G = C + F

    mis = min_informative_str(G)

    reference = """A. Elemwise{add,no_inplace}
	B. C
	C. Elemwise{add,no_inplace}
		D. D
		E. E"""

    if mis != reference:
        print '--'+mis+'--'
        print '--'+reference+'--'

    assert mis == reference
