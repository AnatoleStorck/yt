# distutils: libraries = STD_LIBS
# distutils: include_dirs = LIB_DIR
cimport cython
cimport numpy as np

import numpy as np

from yt.geometry.oct_container cimport RAMSESOctreeContainer
from yt.utilities.cython_fortran_utils cimport FortranFile

from yt.utilities.exceptions import YTIllDefinedAMRData

ctypedef np.int32_t INT32_t
ctypedef np.int64_t INT64_t
ctypedef np.float64_t DOUBLE_t

cdef int INT32_SIZE = sizeof(np.int32_t)
cdef int INT64_SIZE = sizeof(np.int64_t)
cdef int DOUBLE_SIZE = sizeof(np.float64_t)

@cython.cpow(True)
@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
@cython.nonecheck(False)
def read_amr(FortranFile f, dict headers,
             np.ndarray[np.int64_t, ndim=1] ngridbound, INT64_t min_level,
             RAMSESOctreeContainer oct_handler):

    cdef INT64_t ncpu, nboundary, max_level, nlevelmax, ncpu_and_bound
    cdef DOUBLE_t nx, ny, nz
    cdef INT64_t ilevel, icpu, n, ndim, skip_len
    cdef INT32_t ng, buffer_size
    cdef np.ndarray[np.int32_t, ndim=2] numbl
    cdef np.ndarray[np.float64_t, ndim=2] pos

    ndim = headers['ndim']
    numbl = headers['numbl']
    nboundary = headers['nboundary']
    nx, ny, nz = (((i-1.0)/2.0) for i in headers['nx'])
    nlevelmax = headers['nlevelmax']
    ncpu = headers['ncpu']

    ncpu_and_bound = nboundary + ncpu

    pos = np.empty((0, 3), dtype=np.float64)
    buffer_size = 0
    # Compute number of fields to skip. This should be 31 in 3 dimensions
    skip_len = (1          # father index
                + 2*ndim   # neighbor index
                + 2**ndim  # son index
                + 2**ndim  # cpu map
                + 2**ndim  # refinement map
    )
    # Initialize values
    max_level = 0
    for ilevel in range(nlevelmax):
        for icpu in range(ncpu_and_bound):
            if icpu < ncpu:
                ng = numbl[ilevel, icpu]
            else:
                ng = ngridbound[icpu - ncpu + nboundary*ilevel]

            if ng == 0:
                continue
            # Skip grid index, 'next' and 'prev' arrays (they are used
            # to build the linked list in RAMSES)
            f.skip(3)

            # Allocate more memory if required
            if ng > buffer_size:
                pos = np.empty((ng, 3), dtype="d")
                buffer_size = ng

            pos[:ng, 0] = f.read_vector("d") - nx
            pos[:ng, 1] = f.read_vector("d") - ny
            pos[:ng, 2] = f.read_vector("d") - nz

            # Skip father, neighbor, son, cpu map and refinement map
            f.skip(skip_len)
            # Note that we're adding *grids*, not individual cells.
            if ilevel >= min_level:
                n = oct_handler.add(icpu + 1, ilevel - min_level, pos[:ng, :],
                                    count_boundary = 1)
                if n > 0:
                    max_level = max(ilevel - min_level, max_level)

    return max_level


cdef inline int skip_len(int Nskip, int record_len) noexcept nogil:
    return Nskip * (record_len * DOUBLE_SIZE + INT64_SIZE)

@cython.cpow(True)
@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
@cython.nonecheck(False)
cpdef read_offset(FortranFile f, INT64_t min_level, INT64_t domain_id, INT64_t nvar, dict headers, int Nskip):

    cdef np.ndarray[np.int64_t, ndim=2] offset, level_count
    cdef INT64_t ndim, twotondim, nlevelmax, n_levels, nboundary, ncpu, ncpu_and_bound
    cdef INT64_t ilevel, icpu
    cdef INT32_t file_ilevel, file_ncache

    ndim = headers['ndim']
    nboundary = headers['nboundary']
    nlevelmax = headers['nlevelmax']
    n_levels = nlevelmax - min_level
    ncpu = headers['ncpu']

    ncpu_and_bound = nboundary + ncpu
    twotondim = 2**ndim

    if Nskip == -1:
        Nskip = twotondim * nvar

    # It goes: level, CPU, 8-variable (1 oct)
    offset = np.full((ncpu_and_bound, n_levels), -1, dtype=np.int64)
    level_count = np.zeros((ncpu_and_bound, n_levels), dtype=np.int64)

    cdef np.int64_t[:, ::1] level_count_view = level_count
    cdef np.int64_t[:, ::1] offset_view = offset

    for ilevel in range(nlevelmax):
        for icpu in range(ncpu_and_bound):
            file_ilevel = f.read_int()
            file_ncache = f.read_int()
            if file_ncache == 0:
                continue

            if file_ilevel != ilevel+1:
                raise YTIllDefinedAMRData(
                    'Cannot read offsets in file %s. The level read '
                    'from data (%s) is not coherent with the expected (%s)',
                    f.name, file_ilevel, ilevel)

            if ilevel >= min_level:
                offset_view[icpu, ilevel - min_level] = f.tell()
                level_count_view[icpu, ilevel - min_level] = <INT64_t> file_ncache
            f.seek(skip_len(Nskip, file_ncache), 1)

    return offset, level_count

@cython.cpow(True)
@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
@cython.nonecheck(False)
def fill_hydro(FortranFile f,
               np.ndarray[np.int64_t, ndim=2] offsets,
               np.ndarray[np.int64_t, ndim=2] level_count,
               list cpu_enumerator,
               np.ndarray[np.uint8_t, ndim=1] levels,
               np.ndarray[np.uint8_t, ndim=1] cell_inds,
               np.ndarray[np.int64_t, ndim=1] file_inds,
               INT64_t ndim, list all_fields, list fields,
               dict tr,
               RAMSESOctreeContainer oct_handler,
               np.ndarray[np.int32_t, ndim=1] domains=np.array([], dtype='int32')):
    cdef INT64_t offset
    cdef dict tmp
    cdef str field
    cdef INT64_t twotondim
    cdef int ilevel, icpu, nlevels, nc, ncpu_selected, nfields_selected
    cdef int i, j, ii

    twotondim = 2**ndim
    nfields_selected = len(fields)

    nlevels = offsets.shape[1]
    ncpu_selected = len(cpu_enumerator)

    cdef np.int64_t[::1] cpu_list = np.asarray(cpu_enumerator, dtype=np.int64)

    cdef np.int64_t[::1] jumps = np.zeros(nfields_selected + 1, dtype=np.int64)
    cdef int jump_len
    cdef np.ndarray[np.float64_t, ndim=3] buffer

    jump_len = 0
    j = 0
    for i, field in enumerate(all_fields):
        if field in fields:
            jumps[j] = jump_len
            j += 1
            jump_len = 0
        else:
            jump_len += 1
    jumps[j] = jump_len
    cdef int first_field_index = jumps[0]

    buffer = np.empty((level_count.max(), twotondim, nfields_selected), dtype="float64", order='F')
    # Loop over levels
    for ilevel in range(nlevels):
        # Loop over cpu domains
        for ii in range(ncpu_selected):
            icpu = cpu_list[ii]
            nc = level_count[icpu, ilevel]
            if nc == 0:
                continue
            offset = offsets[icpu, ilevel]
            if offset == -1:
                continue
            f.seek(offset + skip_len(first_field_index, nc))

            # We have already skipped the first fields (if any)
            # so we "rewind" (this will cancel the first seek)
            jump_len = -first_field_index
            for i in range(twotondim):
                # Read the selected fields
                for j in range(nfields_selected):
                    jump_len += jumps[j]
                    if jump_len > 0:
                        f.seek(skip_len(jump_len, nc), 1)
                        jump_len = 0
                    f.read_vector_inplace('d', <void*> &buffer[0, i, j])

                jump_len += jumps[nfields_selected]

            # In principle, we may be left with some fields to skip
            # but since we're doing an absolute seek at the beginning of
            # the loop on CPUs, we can spare one seek here
            ## if jump_len > 0:
            ##     f.seek(skip_len(jump_len, nc), 1)

            # Alias buffer into dictionary
            tmp = {}
            for i, field in enumerate(fields):
                tmp[field] = buffer[:, :, i]

            if ncpu_selected > 1:
                oct_handler.fill_level_with_domain(
                    ilevel, levels, cell_inds, file_inds, domains, tr, tmp, domain=icpu+1)
            else:
                oct_handler.fill_level(
                    ilevel, levels, cell_inds, file_inds, tr, tmp)
