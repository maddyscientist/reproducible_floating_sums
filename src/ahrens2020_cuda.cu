#include "common.hpp"
#include "reproducible_floating_accumulator.hpp"

#include <iostream>
#include <random>
#include <unordered_map>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <cub/cub.cuh>

constexpr int block_size = 128; // threads per block
constexpr int M = 4;            // elements per thread array

template <class Accumulator>
__host__ __device__
std::enable_if_t<std::is_same_v<Accumulator, ReproducibleFloatingAccumulator<typename Accumulator::ftype, Accumulator::FOLD>>, Accumulator>
operator+(const Accumulator &lhs, const Accumulator &rhs)
{
  Accumulator rtn = lhs;
  rtn += rhs;
  return rtn;
}

template <int block_size, class T>
__device__ auto block_sum(T value)
{
  // Specialize BlockReduce for a 1D block of 128 threads of type int
  using BlockReduce = cub::BlockReduce<T, block_size>;
  // Allocate shared memory for BlockReduce
  __shared__ typename BlockReduce::TempStorage temp_storage;
  // Compute the block-wide sum for thread0
  return BlockReduce(temp_storage).Sum(value);
}

///Tests summing many numbers one at a time without a known absolute value caps
template <class FloatType, int block_size, class Accumulator>
__global__ void kernel_1(FloatType *sum, FloatType *x, size_t N, Accumulator rfa) {
  auto tid = threadIdx.x;

  // first do thread private reduction
  for (auto i = tid; i < N; i+= blockDim.x) rfa += x[i];

  // Compute the block-wide sum for thread0
  auto aggregate = block_sum<block_size>(rfa);
  if (tid == 0) *sum = aggregate.conv();
}

template<class FloatType>
FloatType bitwise_deterministic_summation_1(const thrust::host_vector<FloatType> &vec){
  thrust::device_vector<FloatType> d_vec = vec;
  thrust::device_vector<FloatType> d_out(1);
  ReproducibleFloatingAccumulator<FloatType> rfa;
  kernel_1<FloatType, block_size><<<1, block_size>>>(thrust::raw_pointer_cast(d_out.data()), thrust::raw_pointer_cast(d_vec.data()), vec.size(), rfa);
  thrust::host_vector<FloatType> out = d_out;
  return out[0];
}

///Tests summing many numbers without a known absolute value caps
template <int block_size, int M, class FloatType, class Accumulator>
__global__ void kernel_many(FloatType *sum, FloatType *x, size_t N, Accumulator rfa) {
  auto tid = threadIdx.x;

  // first do thread private reduction
  for (auto i = tid; i < N; i+= M * blockDim.x) {
    FloatType y[M] = {};
    for (auto j = 0; j < M; j++) {
      y[j] = (i + j * blockDim.x) < N ? x[i + j * blockDim.x] : 0.0;
    }
    rfa.add(y, M);
  }

  // Compute the block-wide sum for thread0
  auto aggregate = block_sum<block_size>(rfa);
  if (tid == 0) *sum = aggregate.conv();
}

template<class FloatType>
FloatType bitwise_deterministic_summation_many(const thrust::host_vector<FloatType> &vec){
  thrust::device_vector<FloatType> d_vec = vec;
  thrust::device_vector<FloatType> d_out(1);
  ReproducibleFloatingAccumulator<FloatType> rfa;
  kernel_many<block_size, M, FloatType><<<1, block_size>>>(thrust::raw_pointer_cast(d_out.data()), thrust::raw_pointer_cast(d_vec.data()), vec.size(), rfa);
  thrust::host_vector<FloatType> out = d_out;
  return out[0];
}

///Tests summing many numbers with a known absolute value caps
template <int block_size, int M, class FloatType, class Accumulator>
__global__ void kernel_manyc(FloatType *sum, FloatType *x, size_t N, FloatType max_abs_val, Accumulator rfa) {
  auto tid = threadIdx.x;

  // first do thread private reduction
  for (auto i = tid; i < N; i+= M * blockDim.x) {
    FloatType y[M] = {};
    FloatType max_y = 0.0;
    for (auto j = 0; j < M; j++) {
      y[j] = (i + j * blockDim.x) < N ? x[i + j * blockDim.x] : 0.0;
      max_y = fabs(y[j]) > max_y ? fabs(y[j]) : max_y;
    }
    rfa.add(y, M, max_y);
  }

  // Compute the block-wide sum for thread0
  auto aggregate = block_sum<block_size>(rfa);
  if (tid == 0) *sum = aggregate.conv();
}

template<class FloatType>
FloatType bitwise_deterministic_summation_manyc(const thrust::host_vector<FloatType> &vec, const FloatType max_abs_val){
  thrust::device_vector<FloatType> d_vec = vec;
  thrust::device_vector<FloatType> d_out(1);
  ReproducibleFloatingAccumulator<FloatType> rfa;
  kernel_manyc<block_size, M, FloatType><<<1, block_size>>>(thrust::raw_pointer_cast(d_out.data()), thrust::raw_pointer_cast(d_vec.data()), vec.size(), max_abs_val, rfa);
  thrust::host_vector<FloatType> out = d_out;
  return out[0];
}


// Timing tests for the summation algorithms
template<class FloatType, class SimpleAccumType>
FloatType PerformTestsOnData(
  const int TESTS,
  thrust::host_vector<FloatType> floats, //Make a copy so we use the same data for each test
  std::mt19937 gen               //Make a copy so we use the same data for each test
){
  Timer time_deterministic_1;
  Timer time_deterministic_many;
  Timer time_deterministic_manyc;
  Timer time_kahan;
  Timer time_simple;

  //Very precise output
  std::cout.precision(std::numeric_limits<FloatType>::max_digits10);
  std::cout<<std::fixed;

  std::cout<<"'1ata' tests summing many numbers one at a time without a known absolute value caps"<<std::endl;
  std::cout<<"'many' tests summing many numbers without a known absolute value caps"<<std::endl;
  std::cout<<"'manyc' tests summing many numbers with a known absolute value caps\n"<<std::endl;

  std::cout<<"Floating type                        = "<<typeid(FloatType).name()<<std::endl;
  std::cout<<"Simple summation accumulation type   = "<<typeid(SimpleAccumType).name()<<std::endl;

  //Get a reference value
  std::unordered_map<FloatType, uint32_t> simple_sums;
  std::unordered_map<FloatType, uint32_t> kahan_sums;
  const auto ref_val = bitwise_deterministic_summation_1<FloatType>(floats);
  const auto kahan_ldsum = serial_kahan_summation<long double>(floats);
  for(int test=0;test<TESTS;test++){
    std::shuffle(floats.begin(), floats.end(), gen);

    time_deterministic_1.start();
    const auto my_val_1 = bitwise_deterministic_summation_1<FloatType>(floats);
    time_deterministic_1.stop();
    if(ref_val!=my_val_1){
      std::cout<<"ERROR: UNEQUAL VALUES ON TEST #"<<test<<" for add-1!"<<std::endl;
      std::cout<<"Reference      = "<<ref_val                    <<std::endl;
      std::cout<<"Current        = "<<my_val_1                   <<std::endl;
      std::cout<<"Reference bits = "<<binrep<FloatType>(ref_val) <<std::endl;
      std::cout<<"Current   bits = "<<binrep<FloatType>(my_val_1)<<std::endl;
      throw std::runtime_error("Values were not equal!");
    }

    time_deterministic_many.start();
    const auto my_val_many = bitwise_deterministic_summation_many<FloatType>(floats);
    time_deterministic_many.stop();
    if(ref_val!=my_val_many){
      std::cout<<"ERROR: UNEQUAL VALUES ON TEST #"<<test<<" for add-many!"<<std::endl;
      std::cout<<"Reference      = "<<ref_val                       <<std::endl;
      std::cout<<"Current        = "<<my_val_many                   <<std::endl;
      std::cout<<"Reference bits = "<<binrep<FloatType>(ref_val)    <<std::endl;
      std::cout<<"Current   bits = "<<binrep<FloatType>(my_val_many)<<std::endl;
      throw std::runtime_error("Values were not equal!");
    }

    time_deterministic_manyc.start();
    const auto my_val_manyc = bitwise_deterministic_summation_manyc<FloatType>(floats, 1000);
    time_deterministic_manyc.stop();
    if(ref_val!=my_val_manyc){
      std::cout<<"ERROR: UNEQUAL VALUES ON TEST #"<<test<<" for add-many!"<<std::endl;
      std::cout<<"Reference      = "<<ref_val                        <<std::endl;
      std::cout<<"Current        = "<<my_val_manyc                   <<std::endl;
      std::cout<<"Reference bits = "<<binrep<FloatType>(ref_val)     <<std::endl;
      std::cout<<"Current   bits = "<<binrep<FloatType>(my_val_manyc)<<std::endl;
      throw std::runtime_error("Values were not equal!");
    }

    time_kahan.start();
    const auto kahan_sum = serial_kahan_summation<FloatType>(floats);
    kahan_sums[kahan_sum]++;
    time_kahan.stop();

    time_simple.start();
    const auto simple_sum = serial_simple_summation<SimpleAccumType>(floats);
    simple_sums[simple_sum]++;
    time_simple.stop();
  }

  std::cout<<"Average deterministic sum 1ata time  = "<<(time_deterministic_1.total/TESTS)<<std::endl;
  std::cout<<"Average deterministic sum many time  = "<<(time_deterministic_many.total/TESTS)<<std::endl;
  std::cout<<"Average deterministic sum manyc time = "<<(time_deterministic_manyc.total/TESTS)<<std::endl;
  std::cout<<"Average simple summation time        = "<<(time_simple.total/TESTS)<<std::endl;
  std::cout<<"Average Kahan summation time         = "<<(time_kahan.total/TESTS)<<std::endl;
  std::cout<<"Ratio Deterministic 1ata to Simple   = "<<(time_deterministic_1.total/time_simple.total)<<std::endl;
  std::cout<<"Ratio Deterministic 1ata to Kahan    = "<<(time_deterministic_1.total/time_kahan.total)<<std::endl;
  std::cout<<"Ratio Deterministic many to Simple   = "<<(time_deterministic_many.total/time_simple.total)<<std::endl;
  std::cout<<"Ratio Deterministic many to Kahan    = "<<(time_deterministic_many.total/time_kahan.total)<<std::endl;
  std::cout<<"Ratio Deterministic manyc to Simple  = "<<(time_deterministic_manyc.total/time_simple.total)<<std::endl;
  std::cout<<"Ratio Deterministic manyc to Kahan   = "<<(time_deterministic_manyc.total/time_kahan.total)<<std::endl;

  std::cout<<"Error bound                          = "<<ReproducibleFloatingAccumulator<FloatType>::error_bound(floats.size(), 1000, ref_val)<<std::endl;

  std::cout<<"Reference value                      = "<<std::fixed<<ref_val<<std::endl;
  std::cout<<"Reference bits                       = "<<binrep<FloatType>(ref_val)<<std::endl;

  std::cout<<"Kahan long double accumulator value  = "<<kahan_ldsum<<std::endl;
  std::cout<<"Distinct Kahan values                = "<<kahan_sums.size()<<std::endl;
  std::cout<<"Distinct Simple values               = "<<simple_sums.size()<<std::endl;

  for(const auto &kv: kahan_sums){
    //std::cout<<"Kahan sum values (N="<<std::fixed<<kv.second<<") "<<kv.first<<" ("<<binrep<FloatType>(kv.first)<<")"<<std::endl;
  }

  for(const auto &kv: simple_sums){
    // std::cout<<"Simple sum values (N="<<std::fixed<<kv.second<<") "<<kv.first<<" ("<<binrep<FloatType>(kv.first)<<")"<<std::endl;
  }

  std::cout<<std::endl;

  return ref_val;
}

// Use this to make sure the tests are reproducible
template<class FloatType, class SimpleAccumType>
void PerformTestsOnUniformRandom(const int N, const int TESTS){
  std::mt19937 gen(123456789);
  std::uniform_real_distribution<double> distr(-1000, 1000);
  thrust::host_vector<double> floats;
  for(int i=0;i<N;i++){
    floats.push_back(distr(gen));
  }
  thrust::host_vector<FloatType> input(floats.begin(), floats.end());

  std::cout<<"Input Data                           = Uniform Random"<<std::endl;
  PerformTestsOnData<FloatType, SimpleAccumType>(TESTS, input, gen);
}

// Use this to make sure the tests are reproducible
template<class FloatType, class SimpleAccumType>
void PerformTestsOnSineWaveData(const int N, const int TESTS){
  std::mt19937 gen(123456789);
  thrust::host_vector<FloatType> input;
  input.reserve(N);
  // Make a sine wave
  for(int i = 0; i < N; i++){
    input.push_back(std::sin(2 * M_PI * (i / static_cast<double>(N) - 0.5)));
  }
  std::cout<<"Input Data                           = Sine Wave"<<std::endl;
  PerformTestsOnData<FloatType, SimpleAccumType>(TESTS, input, gen);
}

int main(){
  const int N = 1'000'000;
  const int TESTS = 100;

  PerformTestsOnUniformRandom<float, float>(N, TESTS);
  PerformTestsOnUniformRandom<double, double>(N, TESTS);

  PerformTestsOnSineWaveData<float, float>(N, TESTS);
  PerformTestsOnSineWaveData<double, double>(N, TESTS);

  return 0;
}
