/* depot_hash - the stable part fingerprint the depot stamps on an index.
 *
 * A tiny C extension on purpose: the depot wants the same fingerprint from
 * every machine that ever builds the index, so the routine is compiled rather
 * than interpreted.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#define FNV_OFFSET 1469598103934665603ULL
#define FNV_PRIME  1099511628211ULL

static PyObject *
depot_hash_fingerprint(PyObject *self, PyObject *args)
{
    const char *data;
    Py_ssize_t length;
    unsigned long long h = FNV_OFFSET;
    Py_ssize_t i;
    char out[17];

    if (!PyArg_ParseTuple(args, "s#", &data, &length)) {
        return NULL;
    }
    for (i = 0; i < length; i++) {
        h ^= (unsigned char)data[i];
        h *= FNV_PRIME;
    }
    PyOS_snprintf(out, sizeof(out), "%016llx", h);
    return PyUnicode_FromString(out);
}

static PyMethodDef DepotHashMethods[] = {
    {"fingerprint", depot_hash_fingerprint, METH_VARARGS,
     "Return the 16-character depot fingerprint of a string."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef depot_hash_module = {
    PyModuleDef_HEAD_INIT,
    "depot_hash",
    "Stable depot fingerprints.",
    -1,
    DepotHashMethods
};

PyMODINIT_FUNC
PyInit_depot_hash(void)
{
    return PyModule_Create(&depot_hash_module);
}
