#include <sstream>
#include <stdexcept>

#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <ctime>

#include <cuda_runtime.h>

#include <thrust/sort.h>
#include <thrust/device_vector.h>
#include <thrust/tuple.h>
#include <thrust/iterator/zip_iterator.h>

#define restrict __restrict__

typedef unsigned int uint;
typedef unsigned int hashKey;
typedef ushort4 particleinfo;

static __forceinline__ __host__ __device__ __attribute__((pure)) const ushort& type(const particleinfo &info)
{ return info.x; }

static __forceinline__ __host__ __device__ __attribute__((pure)) uint id(const particleinfo &info)
{ return (uint)(info.z) | ((uint)(info.w) << 16); }

#define PART_FLAG_SHIFT	3
#define PART_TYPE_MASK	((1<<PART_FLAG_SHIFT)-1)
#define PART_TYPE(f) (type(f) & PART_TYPE_MASK)

/// Functor to sort particles by hash (cell), and
/// by fluid number within the cell
struct ptype_hash_compare :
	public thrust::binary_function<
		thrust::tuple<hashKey, particleinfo>,
		thrust::tuple<hashKey, particleinfo>,
		bool>
{
	typedef thrust::tuple<hashKey, particleinfo> value_type;

	__host__ __device__
	bool operator()(const value_type& a, const value_type& b)
	{
		uint	ha(thrust::get<0>(a)),
			hb(thrust::get<0>(b));
		particleinfo	pa(thrust::get<1>(a)),
				pb(thrust::get<1>(b));

		if (ha == hb) {
			if (PART_TYPE(pa) == PART_TYPE(pb))
				return id(pa) < id(pb);
			return (PART_TYPE(pa) < PART_TYPE(pb));
		}
		return (ha < hb);
	}
};

void
sort(particleinfo *info, hashKey *hash, uint *partidx, uint numParticles)
{
	thrust::device_ptr<particleinfo> particleInfo =
		thrust::device_pointer_cast(info);
	thrust::device_ptr<hashKey> particleHash =
		thrust::device_pointer_cast(hash);
	thrust::device_ptr<uint> particleIndex =
		thrust::device_pointer_cast(partidx);

	ptype_hash_compare comp;

	// Sort of the particle indices by cell hash, fluid number and id
	// There is no need for a stable sort due to the id sort
	thrust::sort_by_key(
		thrust::make_zip_iterator(thrust::make_tuple(particleHash, particleInfo)),
		thrust::make_zip_iterator(thrust::make_tuple(
			particleHash + numParticles,
			particleInfo + numParticles)),
		particleIndex, comp);
}

__global__ void
initParticles(
	particleinfo * restrict infoArray,
	hashKey * restrict hashArray,
	uint * restrict idxArray,
	uint numParticles)
{
	uint idx = threadIdx.x + blockIdx.x*blockDim.x;

	if (idx > numParticles)
		return;

	idxArray[idx] = idx;

	particleinfo info;
	info.x = idx % 4;
	info.y = 0;
	info.z = (ushort)(idx & 0xffff);
	info.w = (ushort)(idx >> 16);

	infoArray[idx] = info;

	hashArray[idx] = idx/17 + (idx % (idx & 17));
}

__global__ void
reHashParticles(
	particleinfo const * restrict infoArray,
	hashKey * restrict hashArray,
	uint const * restrict idxArray,
	uint numParticles)
{
	uint idx = threadIdx.x + blockIdx.x*blockDim.x;

	if (idx > numParticles)
		return;

	hashKey oldHash = hashArray[idx];
	const particleinfo info = infoArray[idx];
	const uint pid = id(info);

	hashArray[idx] = pid/17 + (oldHash % (pid & 17));
}

using namespace std;

void timestamp(FILE* infostream, string msg)
{
	static long int init_pos = 0;

	char timestamp[36] = {0};
	time_t t;
	struct tm *tmp;
	size_t wrt = 0;
	t = time(NULL);
	tmp = localtime(&t);
	if (tmp) {
		wrt = strftime(timestamp, 36, "[%Y-%m-%dT%H:%M:%S] ", tmp);
	}
	if (!wrt) {
		snprintf(timestamp, 36, "[unknown]");
	}
	fprintf(infostream, "%s: %s\n", timestamp, msg.c_str());
	if (init_pos)
		fseek(infostream, init_pos, SEEK_SET);
	else
		init_pos = ftell(infostream);
}

int main(int argc, char *argv[])
{
	stringstream scratch;
	string info_name;

	scratch << "/titanxfall-" << getpid();

	info_name = scratch.str();
	scratch.str("");

	int ret = shm_open(info_name.c_str(), O_RDWR | O_CREAT, S_IRWXU);
	if (ret < 0)
		throw runtime_error("can't open info stream");

	FILE *infostream = fdopen(ret, "w");
	if (!infostream)
		throw runtime_error("can't fdopen info stream");

	timestamp(infostream, "initializing");
	cout << "Initializing " << getpid() << " ..." << endl;

	uint numParticles = 5*1024*1024;

	unsigned long counter = 0;

	particleinfo *info = NULL;
	hashKey *hash = NULL;
	uint *partidx = NULL;

	cudaMalloc(&info, numParticles*sizeof(*info));
	cudaMalloc(&hash, numParticles*sizeof(*hash));
	cudaMalloc(&partidx, numParticles*sizeof(*partidx));

	const int blockSize = 1024;
	const int numBlocks = (numParticles + blockSize - 1)/blockSize;

	initParticles<<<numBlocks, blockSize>>>(info, hash, partidx, numParticles);

	cudaError_t err = cudaGetLastError();
	if (cudaSuccess != err) {
		scratch << __FILE__ << ":" << __LINE__ << ": in initParticles"
			<< ": runtime API error " << err << " (" << cudaGetErrorString(err) << ")";
		throw runtime_error(scratch.str());
	}

	while (true) {
		reHashParticles<<<numBlocks, blockSize>>>(info, hash, partidx, numParticles);

		err = cudaGetLastError();
		if (cudaSuccess != err) {
			scratch << __FILE__ << ":" << __LINE__ << ": in reHashParticles"
				<< ": runtime API error " << err << " (" << cudaGetErrorString(err) << ")";
			throw runtime_error(scratch.str());
		}

		sort(info, hash, partidx, numParticles);

		err = cudaGetLastError();
		if (cudaSuccess != err) {
			scratch << __FILE__ << ":" << __LINE__ << ": in sort"
				<< ": runtime API error " << err << " (" << cudaGetErrorString(err) << ")";
			throw runtime_error(scratch.str());
		}

		++counter;

		scratch << "iteration " << counter;

		timestamp(infostream, scratch.str());
		scratch.str("");

		if (counter % 1000 == 0)
			cout << "Iteration " << counter << endl;
	}
}
