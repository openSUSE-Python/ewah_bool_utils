cimport pyembree.rtcore as rtc
cimport pyembree.rtcore_ray as rtcr
from pyembree.rtcore cimport Vec3f, Triangle, Vertex
from yt.utilities.lib.mesh_construction cimport UserData
from yt.utilities.lib.element_mappings import Q1Sampler3D
cimport numpy as np
cimport cython
from libc.math cimport fabs, fmax

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef inline double determinant_3x3(double* col0, 
                                   double* col1, 
                                   double* col2) nogil:
    return col0[0]*col1[1]*col2[2] - col0[0]*col1[2]*col2[1] - \
           col0[1]*col1[0]*col2[2] + col0[1]*col1[2]*col2[0] + \
           col0[2]*col1[0]*col2[1] + col0[2]*col1[1]*col2[0]

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef inline void func(double* f,
                      double* x, 
                      double* vertices, 
                      double* phys_x) nogil:
    
    cdef int i
    cdef double rm, rp, sm, sp, tm, tp
    
    rm = 1.0 - x[0]
    rp = 1.0 + x[0]
    sm = 1.0 - x[1]
    sp = 1.0 + x[1]
    tm = 1.0 - x[2]
    tp = 1.0 + x[2]
    
    for i in range(3):
        f[i] = vertices[0 + i]*rm*sm*tm \
             + vertices[3 + i]*rp*sm*tm \
             + vertices[6 + i]*rm*sp*tm \
             + vertices[9 + i]*rp*sp*tm \
             + vertices[12 + i]*rm*sm*tp \
             + vertices[15 + i]*rp*sm*tp \
             + vertices[18 + i]*rm*sp*tp \
             + vertices[21 + i]*rp*sp*tp \
             - 8.0*phys_x[i]

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef inline void J(double* r,
                   double* s,
                   double* t,
                   double* x, 
                   double* v, 
                   double* phys_x) nogil:
    
    cdef int i
    cdef double rm, rp, sm, sp, tm, tp
    
    rm = 1.0 - x[0]
    rp = 1.0 + x[0]
    sm = 1.0 - x[1]
    sp = 1.0 + x[1]
    tm = 1.0 - x[2]
    tp = 1.0 + x[2]
    
    for i in range(3):
        r[i] = -sm*tm*v[0 + i]  + sm*tm*v[3 + i]  - \
                sp*tm*v[6 + i]  + sp*tm*v[9 + i]  - \
                sm*tp*v[12 + i] + sm*tp*v[15 + i] - \
                sp*tp*v[18 + i] + sp*tp*v[21 + i]
        s[i] = -rm*tm*v[0 + i]  - rp*tm*v[3 + i]  + \
                rm*tm*v[6 + i]  + rp*tm*v[9 + i]  - \
                rm*tp*v[12 + i] - rp*tp*v[15 + i] + \
                rm*tp*v[18 + i] + rp*tp*v[21 + i]
        t[i] = -rm*sm*v[0 + i]  - rp*sm*v[3 + i]  - \
                rm*sp*v[6 + i]  - rp*sp*v[9 + i]  + \
                rm*sm*v[12 + i] + rp*sm*v[15 + i] + \
                rm*sp*v[18 + i] + rp*sp*v[21 + i]
                
                
@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef double sample_at_unit_point(double* coord, double* vals) nogil:
    cdef double F, rm, rp, sm, sp, tm, tp
    
    rm = 1.0 - coord[0]
    rp = 1.0 + coord[0]
    sm = 1.0 - coord[1]
    sp = 1.0 + coord[1]
    tm = 1.0 - coord[2]
    tp = 1.0 + coord[2]
    
    F = vals[0]*rm*sm*tm + vals[1]*rp*sm*tm + vals[2]*rm*sp*tm + vals[3]*rp*sp*tm + \
        vals[4]*rm*sm*tp + vals[5]*rp*sm*tp + vals[6]*rm*sp*tp + vals[7]*rp*sp*tp
    return 0.125*F
                
@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef double maxnorm(double* f) nogil:
    cdef double err
    cdef int i
    err = fabs(f[0])
    for i in range(1, 2):
        err = fmax(err, fabs(f[i])) 
    return err


cdef double get_value_trilinear(void* userPtr,
                                rtcr.RTCRay& ray):
    cdef int ray_id
    cdef double u, v, val
    cdef double d0, d1, d2

    data = <UserData*> userPtr
    ray_id = ray.primID

    u = ray.u
    v = ray.v

    d0 = data.field_data[ray_id].x
    d1 = data.field_data[ray_id].y
    d2 = data.field_data[ray_id].z

    return d0*(1.0 - u - v) + d1*u + d2*v

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef double sample_at_real_point(double* vertices,
                                 double* field_values,
                                 double* physical_x):
    
    cdef int i
    cdef double d, val
    cdef double[3] f
    cdef double[3] r
    cdef double[3] s
    cdef double[3] t
    cdef double[3] x
    cdef double tolerance = 1.0e-9
    cdef int iterations = 0
    cdef double err
   
    # initial guess
    for i in range(3):
        x[i] = 0.0
    
    # initial error norm
    func(f, x, vertices, physical_x)
    err = maxnorm(f)  
   
    # begin Newton iteration
    while (err > tolerance and iterations < 10):
        J(r, s, t, x, vertices, physical_x)
        d = determinant_3x3(r, s, t)
        x[0] = x[0] - (determinant_3x3(f, s, t)/d)
        x[1] = x[1] - (determinant_3x3(r, f, t)/d)
        x[2] = x[2] - (determinant_3x3(r, s, f)/d)
        func(f, x, vertices, physical_x)        
        err = maxnorm(f)
        iterations += 1
        
    val = sample_at_unit_point(x, field_values)
    return val
    
cdef void sample_surface_hex(void* userPtr,
                             rtcr.RTCRay& ray):
    cdef int ray_id, elem_id, i
    cdef double u, v, val
    cdef double d0, d1, d2
    cdef double[8] field_data
    cdef long[8] element_indices
    cdef double[24] vertices
    cdef double[3] position
    cdef double result
    cdef UserData* data

    data = <UserData*> userPtr
    ray_id = ray.primID
    if ray_id == -1:
        return

    elem_id = ray_id / data.tpe

    get_hit_position(position, userPtr, ray)
    
    for i in range(8):
        element_indices[i] = data.element_indices[elem_id*8+i]
        field_data[i] = data.field_data[elem_id*8+i]

    for i in range(8):
        vertices[i*3] = data.vertices[element_indices[i]].x
        vertices[i*3 + 1] = data.vertices[element_indices[i]].y
        vertices[i*3 + 2] = data.vertices[element_indices[i]].z    

    val = sample_at_real_point(vertices, field_data, position)
    ray.time = val

cdef void get_hit_position(double* position,
                           void* userPtr,
                           rtcr.RTCRay& ray):
    cdef int primID, elemID, i
    cdef double[3][3] vertex_positions
    cdef Triangle tri
    cdef UserData* data

    primID = ray.primID
    data = <UserData*> userPtr
    tri = data.indices[primID]

    vertex_positions[0][0] = data.vertices[tri.v0].x
    vertex_positions[0][1] = data.vertices[tri.v0].y
    vertex_positions[0][2] = data.vertices[tri.v0].z

    vertex_positions[1][0] = data.vertices[tri.v1].x
    vertex_positions[1][1] = data.vertices[tri.v1].y
    vertex_positions[1][2] = data.vertices[tri.v1].z

    vertex_positions[2][0] = data.vertices[tri.v2].x
    vertex_positions[2][1] = data.vertices[tri.v2].y
    vertex_positions[2][2] = data.vertices[tri.v2].z

    for i in range(3):
        position[i] = vertex_positions[0][i]*(1.0 - ray.u - ray.v) + \
                      vertex_positions[1][i]*ray.u + \
                      vertex_positions[2][i]*ray.v
    

cdef void maximum_intensity(void* userPtr, 
                            rtcr.RTCRay& ray):

    cdef double val = get_value_trilinear(userPtr, ray)
    ray.time = max(ray.time, val)
    ray.geomID = -1  # reject hit


cdef void sample_surface(void* userPtr, 
                         rtcr.RTCRay& ray):

    cdef double val = get_value_trilinear(userPtr, ray)
    ray.time = val

