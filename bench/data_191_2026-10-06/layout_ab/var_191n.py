p='pg_fts_am_scan.c'; s=open(p).read()
a="static int\nfts_search_dense1(WandCursor *c, int k, ScoredTid **out)\n{"
assert s.count(a)==1
s=s.replace(a,"pg_noinline static int\nfts_search_dense1(WandCursor *c, int k, ScoredTid **out)\n{")
open(p,'w').write(s)
