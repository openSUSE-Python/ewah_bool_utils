"""
CyOctree building and SPH interpolation routines



"""

#-----------------------------------------------------------------------------
# Copyright (c) 2018, yt Development Team.
#
# Distributed under the terms of the Modified BSD License.
#
# The full license is in the file COPYING.txt, distributed with this software.
#-----------------------------------------------------------------------------

cimport numpy as np
import numpy as np
cimport cython

# for writing to file
import struct

# cpp includes
from libcpp.vector cimport vector
from libcpp cimport bool

# c includes
cimport libc.math as math
from libc.stdlib cimport malloc, free

from yt.geometry.particle_deposit cimport \
    kernel_func, get_kernel_func

# OCTREE IMPLEMENTATION DETAILS:
#
# The tree is made of of Nodes, which are C structs, containing the left edge,
# the right end and other details so traverse (i.e child and parent location)
#
# The Nodes are stored in an STL vector - as such - it makes sense that the
# parent and child addresses are long's which just describe the index in the STL
# vector. I.e to access a parent,
# &nodes[node.parent] will return the address of the parent node
# The children are contiguous in memory, so the first child can be accessed with
# &nodes[node.children] and the second with,
# &nodes[node.children + 1] etc
#
# The tree is built with a non-recursive algorithm. We start my building the
# root node. We enter the root node, and use the split_helper function to split
# into 2**(3*density_factor) children
# NOTE: Despite being called an octree, the tree is actually of splitting into
# different numbers of children
#
# The particles in each node are calculated using the separate utility function.
# This loops through all the particles in the parent node and re-arranges them
# such that they are in the order of which child node they are in. We then store
# the indices of the positions array where the children of that node start and
# stop.
#
# Once the first lot of children have been generated, they will be stored in the
# STL vector like
# nodes = [root, child 1, child 2, child 3, ...]
# we then loop through this vector, calling the process_node method and  storing
# new children as we generate them.
#
# A node will split into children if the Node contains more particles than n_ref
# below this value, the Node will not split, this is called a leaf.
#
# To maintain backwards compatibility we also have the cell structure. This
# means that each leaf is split into 2**(3*over_refine_factor) cells. When an
# SPH field is interpolated onto the octree, we interpolate the value are the
# centre of each cell. The cell locations, and particles they contain, are *NOT*
# stored in memory instead this is calculated on the fly when a interpolation or
# cell position request is made.
# This adds a slight overhead for these functions, but reduces the memory usage
# by 2**(3*over_refine_factor)

cdef struct Node:
    double left_edge[3]
    double right_edge[3]

    np.int64_t start                #  star and end of particles we store
    np.int64_t end

    np.int64_t parent               # position of parent in Octree.nodes
    np.int64_t children             # position of 0th child, children are
                                    # contiguous
    bool leaf
    np.int64_t node_id              # not sure if this is even useful
    np.int64_t leaf_id
    unsigned char depth

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef class CyOctree:
    cdef double _left_edge[3]       # boundary conditions for the octree
    cdef double _right_edge[3]
    cdef np.int64_t[:] _idx         # ordering of particles used by the tree

    cdef int _n_ref                 # number of particles per leaf
    cdef np.int64_t _num_particles

    cdef np.int64_t _data_version

    cdef vector[Node] nodes         # This is an STL container to store the octs

    # Cell structure
    cdef int _over_refine_factor    # this allows the tree to be built with more
                                    # than 8 cells per leaf
    cdef int _num_cells             # 2**(3*_over_refine_factor)
    cdef int _num_cells_per_dim     # 2**(_over_refine_factor)

    # Children structure
    cdef int _density_factor        # this allows the tree to be built with more
                                    # than 8 children per node
    cdef int _num_children          # 2**(3*_density_factor)
    cdef int _num_children_per_dim  # 2**(_density_factor)

    # this is use for interpolation and is global for the octree smoothing
    # operations
    cdef kernel_func kernel

    def __init__(self, double[:, ::1] &input_pos = None, left_edge = None,
                 right_edge = None, int n_ref=32, int over_refine_factor=1,
                 int density_factor=1, np.int64_t data_version=0):

        # if this is the case, we are very likely just initialising an instance
        # and then going to load an existing Octree from memory, so we don't
        # really need to do anything
        if input_pos is None:
            return

        self.data_version = data_version
        self.over_refine_factor = over_refine_factor
        self.density_factor = density_factor
        self.n_ref = n_ref
        self.num_particles = input_pos.shape[0]

        # set up the initial idx of the particles, this keeps track of which
        # particle from the input is in which node
        self.idx = np.arange(0, input_pos.shape[0], dtype=np.int64)

        # set up the bounds and root node
        self.setup_bounds(input_pos, left_edge, right_edge)
        self.setup_root(input_pos)

        # reserve some space for the octs to be stored
        reserve(&self.nodes, 1000000)

        # now build the tree
        self.build_tree(&input_pos[0, 0])

    cdef setup_bounds(self, double[:, ::1] &input_pos, left_edge=None,
                      right_edge=None):
        if left_edge is not None:
            for i in range(3):
                self._left_edge[i] = left_edge[i]
        else:
            for i in range(3):
                self._left_edge[i] = np.amin(input_pos[:,i])

        if right_edge is not None:
            for i in range(3):
                self._right_edge[i] = right_edge[i]
        else:
            for i in range(3):
                self._right_edge[i] = np.amax(input_pos[:,i])

    cdef setup_root(self, double[:, ::1] &input_pos):
        cdef Node root
        root.left_edge = self._left_edge
        root.right_edge = self._right_edge
        root.parent = 0

        root.start = 0
        root.end = input_pos.shape[0]*3

        root.children = 0
        root.leaf = 1
        root.depth = 0
        root.leaf_id = 0
        root.node_id = 0

        # store the root in the nodes array
        self.nodes.push_back(root)

    cdef reset(self):
        # clear the big memory users before we load an octree from memory
        self.nodes.clear()
        self._idx = np.zeros(1, dtype=int)-1

    cdef int build_tree(self, double * input_pos):
        # generate an array to store the which particles are in each child oct
        cdef np.int64_t * split_arr
        split_arr = <np.int64_t*> malloc((self._num_children + 1) *
                                                            sizeof(np.int64_t))

        # loop through the octs in serial and process the nodes, i.e, sort the
        # particles and create the children, which will increase the node.size
        # if we make children, then we iterate through those children
        cdef int num_nodes_processed = 0
        while num_nodes_processed < self.nodes.size():
            self.process_node(&self.nodes[num_nodes_processed], input_pos,
                              split_arr)
            num_nodes_processed += 1

        free(split_arr)

    cdef int process_node(self, Node * node, double * input_pos,
                          np.int64_t * split_arr) nogil:
        if(node.end - node.start <= 3*self._n_ref):
            return 0

        # node is no longer a leaf
        node.leaf = 0

        # this sorts the children in the node and then stores the position of
        # the first and last particle in each node
        split_helper(node.start, node.end, self._num_children,
                     self._num_children_per_dim - 1,
                     split_arr, input_pos, &self._idx[0], &node.left_edge[0],
                     &node.right_edge[0])

        # generate the node structures for the children, and store the position
        # of the first and last particle they contain
        self.generate_children(node, split_arr)

        return 0

    cdef inline void generate_children(self, Node * node,
                                       np.int64_t * split_arr) nogil:
        cdef int i, j, z, k, split_id
        cdef double dx, dy, dz
        cdef Node temp

        node.children = self.nodes.size()

        # set the properties which are the same for all children
        temp.parent = node.node_id
        temp.leaf = 1
        temp.depth = node.depth + 1
        temp.leaf_id = 0

        # set up the values to be used to set the child boundaries
        dx = (node.right_edge[0] - node.left_edge[0]) / self._num_children_per_dim
        dy = (node.right_edge[1] - node.left_edge[1]) / self._num_children_per_dim
        dz = (node.right_edge[2] - node.left_edge[2]) / self._num_children_per_dim

        # loop through and create the children setting the node dependent values
        z = node.children
        split_id = 0
        for i in range(self._num_children_per_dim):
            for j in range(self._num_children_per_dim):
                for k in range(self._num_children_per_dim):
                    temp.left_edge[0] = node.left_edge[0] + i*dx
                    temp.left_edge[1] = node.left_edge[1] + j*dy
                    temp.left_edge[2] = node.left_edge[2] + k*dz
                    temp.right_edge[0] = node.left_edge[0] + (i+1)*dx
                    temp.right_edge[1] = node.left_edge[1] + (j+1)*dy
                    temp.right_edge[2] = node.left_edge[2] + (k+1)*dz
                    temp.node_id = z

                    temp.start = split_arr[split_id]
                    temp.end = split_arr[split_id + 1]

                    self.nodes.push_back(temp)
                    z+=1
                    split_id+=1

    @property
    def size_bytes(self):
        return sizeof(Node) * self.nodes.size()

    @property
    def data_version(self):
        return self._data_version

    @data_version.setter
    def data_version(self, value):
        self._data_version = value

    @property
    def num_particles(self):
        return self._num_particles

    @num_particles.setter
    def num_particles(self, value):
        self._num_particles = value

    @property
    def n_ref(self):
        return self._n_ref

    @n_ref.setter
    def n_ref(self, value):
        self._n_ref = value

    @property
    def num_octs(self):
        return self.nodes.size()

    @property
    def over_refine_factor(self):
        return self._over_refine_factor

    @over_refine_factor.setter
    def over_refine_factor(self, value):
        self._over_refine_factor = value
        self._num_cells = 2**(3 * value)
        self._num_cells_per_dim = 2**value

    @property
    def density_factor(self):
        return self._density_factor

    @density_factor.setter
    def density_factor(self, value):
        self._density_factor = value
        self._num_children = 2**(3 * value)
        self._num_children_per_dim  = 2**value

    @property
    def idx(self):
        return np.asarray(self._idx)

    @idx.setter
    def idx(self, array):
        self._idx = array

    @property
    def cell_positions(self):
        cdef int i, j, z, k, l, num_leaves

        # find all the leafs
        num_leaves = 0
        for i in range(self.nodes.size()):
            if self.nodes[i].leaf == 1:
                num_leaves += 1

        cdef np.float64_t[:, :] pos = np.zeros((num_leaves*self._num_cells, 3),
                                                dtype=float)
        cdef double leftx, lefty, leftz, rightx, righty, rightz
        z = 0
        for i in range(self.nodes.size()):
            if self.nodes[i].leaf == 0:
                continue

            leftx = self.nodes[i].left_edge[0]
            lefty = self.nodes[i].left_edge[1]
            leftz = self.nodes[i].left_edge[2]
            rightx = self.nodes[i].right_edge[0]
            righty = self.nodes[i].right_edge[1]
            rightz = self.nodes[i].right_edge[2]

            self.nodes[i].leaf_id = z

            # we have to generate cell locations
            dx = (rightx - leftx) / self._num_cells_per_dim
            dy = (righty - lefty) / self._num_cells_per_dim
            dz = (rightz - leftz) / self._num_cells_per_dim

            for j in range(self._num_cells_per_dim):
                for k in range(self._num_cells_per_dim):
                    for l in range(self._num_cells_per_dim):
                        pos[z, 0] = leftx + (j + 0.5) * dx
                        pos[z, 1] = lefty + (k + 0.5) * dy
                        pos[z, 2] = leftz + (l + 0.5) * dz
                        z+=1

        return np.asarray(pos)

    cdef void smooth_onto_cells(self, np.float64_t[:] buff,
                                np.float64_t[:] buff_den, np.float64_t posx,
                                np.float64_t posy, np.float64_t posz,
                                np.float64_t hsml, np.float64_t prefactor,
                                np.float64_t prefactor_norm,
                                Node * node,
                                int use_normalization=0):

        cdef Node * child
        cdef int i, j, k, l
        cdef double q_ij, diff_x, diff_y, diff_z, dx, dy, dz, voxel_hsml2
        cdef double leftx, lefty, leftz, rightx, righty, rightz

        if node.leaf == 0:
            child = &self.nodes[node.children]
            for i in range(self._num_children):
                leftx = child[i].left_edge[0]
                lefty = child[i].left_edge[1]
                leftz = child[i].left_edge[2]
                rightx = child[i].right_edge[0]
                righty = child[i].right_edge[1]
                rightz = child[i].right_edge[2]

                if leftx - posx < hsml and posx - rightx < hsml:
                    if lefty - posy < hsml and posy - righty < hsml:
                        if leftz - posz < hsml and posz - rightz < hsml:
                            self.smooth_onto_cells(buff, buff_den, posx,
                                                   posy, posz,
                                                   hsml, prefactor,
                                                   prefactor_norm,
                                                   &child[i],
                                                   use_normalization)
        else:
            leftx = node.left_edge[0]
            lefty = node.left_edge[1]
            leftz = node.left_edge[2]
            rightx = node.right_edge[0]
            righty = node.right_edge[1]
            rightz = node.right_edge[2]

            # we have to generate cell locations
            dx = (rightx - leftx) / self._num_cells_per_dim
            dy = (righty - lefty) / self._num_cells_per_dim
            dz = (rightz - leftz) / self._num_cells_per_dim

            # loop through each cell and calculate the contribution
            l = 0
            for i in range(self._num_cells_per_dim):
                for j in range(self._num_cells_per_dim):
                    for k in range(self._num_cells_per_dim):
                        diff_x = (leftx + (i + 0.5) * dx - posx)
                        diff_x *= diff_x
                        diff_y = (lefty + (j + 0.5) * dy - posy)
                        diff_y *= diff_y
                        diff_z = (leftz + (k + 0.5) * dz - posz)
                        diff_z *= diff_z

                        voxel_hsml2 = hsml*hsml
                        q_ij = math.sqrt((diff_x + diff_y + diff_z) /
                                                                    voxel_hsml2)

                        if use_normalization:
                            buff_den[node.leaf_id + l] += (prefactor_norm *
                                                            self.kernel(q_ij))
                        buff[node.leaf_id + l] += prefactor * self.kernel(q_ij)
                        l += 1

    def interpolate_sph_cells(self, np.float64_t[:] buff,
                              np.float64_t[:] buff_den,
                              np.float64_t[:] posx,
                              np.float64_t[:] posy, np.float64_t[:] posz,
                              np.float64_t[:] pmass, np.float64_t[:] pdens,
                              np.float64_t[:] hsml, np.float64_t[:] field,
                              kernel_name="cubic", int use_normalization=0):

        self.kernel = get_kernel_func(kernel_name)

        cdef int i
        cdef double prefactor, prefactor_norm

        for i in range(posx.shape[0]):
            prefactor = pmass[i] / pdens[i] / hsml[i]**3
            prefactor_norm = prefactor
            prefactor *= field[i]

            self.smooth_onto_cells(buff, buff_den, posx[i], posy[i], posz[i], hsml[i],
                                   prefactor, prefactor_norm, &self.nodes[0],
                                   use_normalization=use_normalization)

    # TODO: this code is much slower than I would like, this is likely due to
    # the use of struct -> plan to replace this. A c++ approach is probably
    # faster and more intuitive
    def save(self, fname = None):
        if fname is None:
            raise ValueError("A filename must be specified to save the octree!")

        with open(fname,'wb') as f:
            f.write(struct.pack('2Q3iq', self.num_particles, self.num_octs,
                                      self.n_ref, self.over_refine_factor,
                                      self.density_factor, self.data_version))
            f.write(struct.pack('{}Q'.format(self.num_particles),
                                *self.idx))
            for i in range(self.num_octs):
                f.write(struct.pack('6d4Q?2Qi',
                                    self.nodes[i].left_edge[0],
                                    self.nodes[i].left_edge[1],
                                    self.nodes[i].left_edge[2],
                                    self.nodes[i].right_edge[0],
                                    self.nodes[i].right_edge[1],
                                    self.nodes[i].right_edge[2],
                                    self.nodes[i].start,
                                    self.nodes[i].end,
                                    self.nodes[i].parent,
                                    self.nodes[i].children,
                                    self.nodes[i].leaf,
                                    self.nodes[i].node_id,
                                    self.nodes[i].leaf_id,
                                    self.nodes[i].depth))

    def load(self, fname = None):
        if fname is None:
            raise ValueError("A filename must be specified to load the octtree!")
        # clear any current tree we have loaded
        self.reset()

        cdef Node temp
        cdef np.int64_t num_octs
        with open(fname,'rb') as f:
            (self.num_particles, num_octs, self.n_ref,
             self.over_refine_factor, self.density_factor,
             self.data_version) = \
                struct.unpack('2Q3iq', f.read(40))
            self.idx = \
                np.asarray(struct.unpack('{}Q'.format(self.num_particles),
                           f.read(8*self.num_particles)), dtype=np.int64)
            reserve(&self.nodes, num_octs+1)
            for i in range(num_octs):
                (temp.left_edge[0], temp.left_edge[1], temp.left_edge[2],
                 temp.right_edge[0], temp.right_edge[1], temp.right_edge[2],
                 temp.start, temp.end, temp.parent, temp.children, temp.leaf,
                 temp.node_id, temp.leaf_id, temp.depth) = \
                struct.unpack('6d4Q?2Qi', f.read(108))

                self.nodes.push_back(temp)

        for i in range(3):
            self._left_edge[i] = self.nodes[0].left_edge[i]
            self._right_edge[i] = self.nodes[0].right_edge[i]

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef int split_helper(int start, int end, int num_children, int max_splits,
                       np.int64_t * split_arr, np.float64_t * pos,
                       np.int64_t * idx, np.float64_t * left,
                       np.float64_t * right) nogil except -1:
    cdef double lower = left[0]
    cdef double upper = right[0]

    split_arr[0] = start
    split_arr[num_children] = end

    split(0, num_children, max_splits, 0, 0, split_arr, idx, pos, left, right,
          lower, upper)

    return 0

# This is a utility function which is able to catch errors when we attempt to
# reserve too much memory
cdef int reserve(vector[Node] * vec, int amount) except +MemoryError:
    vec.reserve(amount)
    return 0

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef int seperate(np.float64_t * array, np.int64_t * idx, int offset,  double value,
                  np.int64_t start, np.int64_t end) nogil except -1:
    cdef np.int64_t index
    cdef np.int64_t idx_index = start // 3, idx_split = idx_index
    cdef np.int64_t split = start

    for index in range(start, end, 3):
        idx_index += 1
        if array[index + offset] < value:
            idx[idx_split], idx[idx_index] = idx[idx_index], idx[idx_split]
            array[split], array[index] = array[index], array[split]
            array[split+1], array[index+1] = array[index+1], array[split+1]
            array[split+2], array[index+2] = array[index+2], array[split+2]
            split+=3
            idx_split+=1

    return split

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef int split(int start, int end, int max_splits, int splits, int axis,
           np.int64_t * split_arr, np.int64_t * idx, np.float64_t * pos,
           np.float64_t * left_edge, np.float64_t * right_edge,
           np.float64_t lower, np.float64_t upper) nogil except -1:
    cdef int mid
    cdef double temp_value

    if splits == max_splits and axis < 2:
        splits = 0
        axis += 1
        lower = left_edge[axis]
        upper = right_edge[axis]

    if splits < max_splits:
        splits += 1
        mid = (start + end) // 2
        temp_value = (upper + lower) / 2

        split_arr[mid] = seperate(pos, idx, axis, temp_value, split_arr[start],
                                  split_arr[end])

        split(start, mid, max_splits, splits, axis, split_arr, idx, pos,
              left_edge, right_edge, lower, temp_value)
        split(mid, end, max_splits, splits, axis, split_arr, idx, pos,
              left_edge, right_edge, temp_value, upper)

    return 0
