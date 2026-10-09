# DIAGNOSTIC ONLY (never committed): when env PGFTS_I6_SHARED=1, the slot chunk
# built by bm25_doclendir_add_slots is published to /dev/shm and every backend
# reads the slot arrays from ONE MAP_SHARED mapping instead of its private copy.
p='pg_fts_am.c'; s=open(p).read()
a="""	MemoryContextDelete(tmp);
	pfree(dc);
	return out;
}"""
assert s.count(a)==1
b="""	MemoryContextDelete(tmp);
	pfree(dc);
	if (getenv("PGFTS_I6_SHARED") != NULL)
	{
		Size		total = MAXALIGN(basesz) + extra;
		char		path[160], tmpp[180];
		int			fd;

		snprintf(path, sizeof(path), "/dev/shm/pgfts_i6_%u_%u_%zu", RelationGetRelid(index), (unsigned) out->generation, total);
		fd = open(path, O_RDONLY);
		if (fd < 0)
		{
			snprintf(tmpp, sizeof(tmpp), "%s.%d", path, MyProcPid);
			fd = open(tmpp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
			if (fd >= 0 && write(fd, out, total) == (ssize_t) total)
			{
				close(fd);
				rename(tmpp, path);
			}
			else if (fd >= 0)
				close(fd);
			fd = open(path, O_RDONLY);
		}
		if (fd >= 0)
		{
			void	   *m = mmap(NULL, total, PROT_READ, MAP_SHARED, fd, 0);

			close(fd);
			if (m != MAP_FAILED)
				i6_map = (const char *) m;
		}
		elog(LOG, "I6 proto: shared slot map %s -> %p", path, i6_map);
	}
	return out;
}"""
s=s.replace(a,b)
a="""					c->slot_base = (const uint32 *) ((const char *) dc + dc->segs[i].slot_base_off);
					c->slot_byte = (const uint8 *) ((const char *) dc + dc->segs[i].slot_byte_off);"""
assert s.count(a)==1
b="""					c->slot_base = (const uint32 *) ((i6_map ? i6_map : (const char *) dc) + dc->segs[i].slot_base_off);
					c->slot_byte = (const uint8 *) ((i6_map ? i6_map : (const char *) dc) + dc->segs[i].slot_byte_off);"""
s=s.replace(a,b)
a="static void\nbm25_doclen_cursor_init(BM25DoclenCursor *c, Relation index, BlockNumber start,"
assert s.count(a)==1
s=s.replace("#include \"pg_fts_for.h\"\n","#include \"pg_fts_for.h\"\n#include <sys/mman.h>\n#include <fcntl.h>\n#include <unistd.h>\nstatic const char *i6_map = NULL;\n",1)
open(p,'w').write(s)
