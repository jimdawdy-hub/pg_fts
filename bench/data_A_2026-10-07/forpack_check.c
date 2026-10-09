/* exhaustive-ish equivalence: new bm25_for_pack vs the old per-bit loop, then decode round-trip */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef uint64_t uint64; typedef uint32_t uint32;

#include "pg_fts_for.h"
static int old_pack(const uint64 *vals, int n, unsigned char *buf){
  uint64 maxv=0; int width,i,bitpos,nbytes; for(i=0;i<n;i++) if(vals[i]>maxv) maxv=vals[i];
  width=bm25_bitwidth(maxv); buf[0]=(unsigned char)width; if(width==0) return 1;
  nbytes=1+(n*width+7)/8; memset(buf+1,0,nbytes-1); bitpos=0;
  for(i=0;i<n;i++){uint64 v=vals[i]; int b; for(b=0;b<width;b++) if(v&((uint64)1<<b)){int abs=bitpos+b; buf[1+(abs>>3)]|=(unsigned char)(1<<(abs&7));} bitpos+=width;}
  return nbytes;}
int main(void){
  unsigned char a[1+128*8+16], b[1+128*8+16]; uint64 v[128], out[128]; long trials=0;
  srand(7);
  for(int width=0; width<=64; width++) for(int rep=0; rep<3000; rep++){
    int n=1+rand()%128;
    for(int i=0;i<n;i++){ uint64 r=((uint64)rand()<<62)^((uint64)rand()<<31)^(uint64)rand();
      v[i]= width==0?0: (width==64? r : (r & ((((uint64)1)<<width)-1))); }
    if(width>0 && rep%2==0) v[rand()%n] = width==64? ~(uint64)0 : ((((uint64)1)<<width)-1);
    memset(a,0xAA,sizeof a); memset(b,0x55,sizeof b);
    int la=old_pack(v,n,a), lb=bm25_for_pack(v,n,b);
    if(la!=lb || memcmp(a,b,la)){ printf("MISMATCH width=%d n=%d\n",width,n); return 1; }
    int lu=bm25_for_unpack(b,n,out); if(lu!=lb){printf("unpack len mismatch\n");return 1;}
    for(int i=0;i<n;i++) if(out[i]!=v[i]){printf("ROUNDTRIP width=%d i=%d\n",width,i);return 1;}
    trials++;
  }
  printf("OK %ld trials, widths 0..64\n", trials); return 0; }
