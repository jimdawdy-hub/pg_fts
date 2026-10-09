/* Like l3test but models pg_fts's slot lookup exactly: per lookup, read
 * base[bi] (uint32 array, nblk+1) and byte[base[bi]+off-1]. private vs shared. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <time.h>
#include <sched.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
int main(int argc,char**argv){
  int P=atoi(argv[1]); int shared=atoi(argv[2]); uint32_t nblk=(uint32_t)atol(argv[3]); int L=atoi(argv[4]); double T=atof(argv[5]);
  uint32_t perblk=5; size_t nslot=(size_t)nblk*perblk;
  uint32_t *bi=malloc(L*4), *off=malloc(L*4); uint64_t s=88172645463325252ull;
  for(int i=0;i<L;i++){s^=s<<13;s^=s>>7;s^=s<<17; bi[i]=(uint32_t)(s%nblk); off[i]=1+(uint32_t)((s>>32)%perblk);}
  for(int i=1;i<L;i++){uint32_t v=bi[i],o=off[i];int j=i-1;while(j>=0&&bi[j]>v){bi[j+1]=bi[j];off[j+1]=off[j];j--;}bi[j+1]=v;off[j+1]=o;}
  size_t sz=(nblk+1)*4+nslot; uint8_t *sh=NULL;
  if(shared){sh=mmap(NULL,sz,PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS,-1,0);}
  uint64_t *cnt=mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS,-1,0);
  if(shared){uint32_t*b=(uint32_t*)sh; for(uint32_t i=0;i<=nblk;i++) b[i]=i*perblk; for(size_t i=0;i<nslot;i++) sh[(nblk+1)*4+i]=(uint8_t)i;}
  for(int p=0;p<P;p++) if(fork()==0){
    uint8_t *m=sh; if(!shared){m=malloc(sz); uint32_t*b=(uint32_t*)m; for(uint32_t i=0;i<=nblk;i++) b[i]=i*perblk; for(size_t i=0;i<nslot;i++) m[(nblk+1)*4+i]=(uint8_t)i;}
    uint32_t *base=(uint32_t*)m; uint8_t *byt=m+(nblk+1)*4;
    double end=now()+T; uint64_t q=0, acc=0;
    while(now()<end){ for(int i=0;i<L;i++) acc+=byt[base[bi[i]]+off[i]-1]; q++; }
    __atomic_add_fetch(&cnt[0],q,__ATOMIC_RELAXED); if(acc==42) puts(""); _exit(0);
  }
  while(wait(NULL)>0);
  printf("P=%d %s nblk=%u L=%d qps=%.0f\n",P,shared?"shared ":"private",nblk,L,cnt[0]/T);
  return 0;
}
