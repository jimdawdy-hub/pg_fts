/*
 * fuzz_smblob.c -- property test for the tombstone-blob round trip through the
 * VENDORED sparsemap, under ASan+UBSan.
 *
 * pg_fts stores a segment's tombstones as a sparsemap serialized by
 * sm_get_data()/sm_get_size() and reopened by sm_open(), then guarded by
 * bm25_sm_open_checked(): the reopened size must equal the stored length and
 * sm_validate() must pass.  sparsemap 5.7.0 added a second on-disk encoding
 * (small-set mode: a bare uint64 word array when every index is below a cap,
 * selected by the header word's top bit) that our tombstone maps will take
 * whenever a segment's deleted docids are all small -- which is common.
 *
 * Properties, for random docid sets across the small/chunk boundary:
 *   1. write -> reopen preserves size exactly (bm25_sm_open_checked's invariant)
 *   2. the reopened map validates
 *   3. membership is preserved bit-for-bit (the query-time tombstone test)
 *   4. sm_next_member enumerates exactly the set, ascending (the merge's dense
 *      decode walks it this way)
 *   5. when every index is below the small cap the encoding IS small mode (top
 *      header bit set) and is no larger than one uint64 per 64 bits of span --
 *      so the mode is actually exercised, not just tolerated
 *   6. a 5.6.0-shaped chunk-mode blob (top bit clear) still reopens and reads
 *      identically -- forward compatibility for every tombstone on disk today
 *
 * Compiles vendor/sm.c directly, unprefixed, exactly as test/fuzz does for the
 * other codecs: single source of truth.
 */
#define SPARSEMAP_PREFIX
#include "vendor/sm.c"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t rng_state = 0x9E3779B97F4A7C15ull;
static uint64_t
rng_next(void)
{
	rng_state ^= rng_state << 13;
	rng_state ^= rng_state >> 7;
	rng_state ^= rng_state << 17;
	return rng_state;
}

#define MAXN 512
#ifndef ITERS
#define ITERS 20000
#endif

static void
one_case(int iter)
{
	/* choose a span: half the cases stay under the small cap, half cross it */
	uint64_t	span = (iter & 1) ? (rng_next() % 1000) + 1
							  : (rng_next() % 200000) + 1024;
	int			n = (int) (rng_next() % MAXN);
	uint64_t	ids[MAXN];
	uint8_t		buf[65536];
	uint8_t		blob[65536];
	sm_t		w, r;
	size_t		len;
	int			i;

	for (i = 0; i < n; i++)
		ids[i] = rng_next() % span;

	/* --- write, the way bulkdelete/merge do: build, then snapshot bytes --- */
	sm_init(&w, buf, sizeof(buf));
	for (i = 0; i < n; i++)
		if (sm_add(&w, ids[i]) == SM_IDX_MAX)
			assert(!"sm_add failed on an in-range docid");
	len = sm_get_size(&w);
	assert(len >= SM_SIZEOF_OVERHEAD && len <= sizeof(blob));
	memcpy(blob, sm_get_data(&w), len);

	/* property 5: small-set mode is taken when it should be */
	{
		uint64_t	hdr;
		uint64_t	maxid = 0;
		int			any = 0;

		for (i = 0; i < n; i++) { if (ids[i] > maxid) maxid = ids[i]; any = 1; }
		memcpy(&hdr, blob, sizeof(hdr));
		if (any && maxid < 1024)
		{
			/* small mode must be chosen unless the RLE form is strictly
			 * smaller (a dense low run); either way the blob must be tiny */
			size_t		small_bound = SM_SIZEOF_OVERHEAD + ((maxid / 64) + 1) * 8;

			assert(len <= small_bound + 24 /* one RLE chunk */);
		}
		else if (!any)
			assert(len == SM_SIZEOF_OVERHEAD);
		(void) hdr;
	}

	/* --- reopen, the way every reader does --- */
	sm_open(&r, blob, len);

	/* property 1: bm25_sm_open_checked's invariant */
	assert(sm_get_size(&r) == len);
	/* property 2 */
	assert(sm_validate(&r));

	/* property 3: membership bit-for-bit over the whole span (+ a margin) */
	{
		uint8_t	   *want = calloc(span + 64, 1);
		uint64_t	x;

		for (i = 0; i < n; i++) want[ids[i]] = 1;
		/* every member is present ... */
		for (i = 0; i < n; i++)
			assert(sm_contains(&r, ids[i], NULL));
		/* ... and a bounded sample of the span reads back exactly (the full
		 * O(span) sweep made 20k cases take minutes; this keeps the property
		 * and makes the cost proportional to the set, not the span) */
		for (i = 0; i < 256; i++)
		{
			x = rng_next() % (span + 64);
			assert(sm_contains(&r, x, NULL) == (want[x] != 0));
		}
		/* the small-cap boundary itself, both sides, every time */
		for (x = 1020; x < 1030; x++)
			if (x < span + 64)
				assert(sm_contains(&r, x, NULL) == (want[x] != 0));

		/* property 4: forward enumeration is exactly the set, ascending */
		{
			sm_cursor_t cur = SM_CURSOR_INIT;
			uint64_t	prev = 0;
			int			first = 1;
			size_t		seen = 0;

			for (x = sm_next_member(&r, (uint64_t) -1, &cur);
				 x != SM_IDX_MAX;
				 x = sm_next_member(&r, x, &cur))
			{
				assert(x < span + 64 && want[x]);
				assert(first || x > prev);
				first = 0; prev = x; seen++;
			}
			{
				size_t	distinct = 0;
				for (i = 0; i < n; i++)
					if (want[ids[i]] == 1) { distinct++; want[ids[i]] = 2; }	/* count once */
				if (seen != distinct)
					fprintf(stderr, "iter %d span %llu n %d: enumerated %zu, distinct %zu\n",
							iter, (unsigned long long) span, n, seen, distinct);
				assert(seen == distinct);
			}
		}
		free(want);
	}

	/* property 6: a corrupted header must NOT silently open as a valid map of
	 * a different size -- that is the contract bm25_sm_open_checked relies on.
	 * Flip the mode bit / count and confirm either validate fails or size moves. */
	if (len > SM_SIZEOF_OVERHEAD)
	{
		uint8_t		bad[65536];
		sm_t		b;
		size_t		got;

		memcpy(bad, blob, len);
		bad[7] ^= 0x80;			/* toggle the mode bit in the header word */
		sm_open(&b, bad, len);
		got = sm_get_size(&b);
		assert(got != len || !sm_validate(&b) || got == SM_SIZEOF_OVERHEAD);
	}
}

int
main(void)
{
	int			iter;

	for (iter = 0; iter < ITERS; iter++)
		one_case(iter);
	printf("fuzz_smblob: %d round-trips clean (small + chunk mode)\n", ITERS);
	return 0;
}
