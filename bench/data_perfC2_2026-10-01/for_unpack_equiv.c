#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "new.h"
#include "old.h"
static uint64_t rng=88172645463325252ULL; static uint64_t xr(void){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return rng;}
int main(void){
  long cases=0;
  for(int width=0; width<=64; width++)
  for(int n=0; n<=128; n++)
  for(int rep=0; rep<40; rep++){
    uint64 in[128], a[128], b[128];
    uint64 mask = width==0?0: width>=64? ~0ULL : ((1ULL<<width)-1);
    for(int i=0;i<n;i++){ uint64 v=xr()&mask; if(rep==1) v=mask; if(rep==2) v=0; in[i]=v; }
    if(n>0 && width>0) in[xr()%n]=mask;   /* force the column to actually need `width` bits */
    unsigned char *buf=malloc(1+(128*64+7)/8);
    int plen=bm25_for_pack(in,n,buf);
    unsigned char *exact=malloc(plen); memcpy(exact,buf,plen); free(buf);  /* ASan: no slack past the packed column */
    int l1=bm25_for_unpack(exact,n,a), l2=old_bm25_for_unpack(exact,n,b);
    if(l1!=l2||l1!=plen||memcmp(a,b,n*8)||memcmp(a,in,n*8)){printf("MISMATCH width=%d n=%d rep=%d\n",width,n,rep);return 1;}
    for(int i=0;i<n;i++) if(bm25_for_get(exact,i)!=in[i]){printf("GET MISMATCH\n");return 1;}
    free(exact); cases++;
  }
  printf("OK %ld cases identical (width 0..64, n 0..128)\n",cases); return 0;
}
