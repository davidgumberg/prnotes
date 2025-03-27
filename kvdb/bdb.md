# B-tree pages

Provided this beautiful chart in `db_page.h`:
```c
/************************************************************************
 BTREE/HASH MAIN PAGE LAYOUT
 ************************************************************************/
/*
 *	+-----------------------------------+
 *	|    lsn    |   pgno    | prev pgno |
 *	+-----------------------------------+
 *	| next pgno |  entries  | hf offset |
 *	+-----------------------------------+
 *	|   level   |   type    |   chksum  |
 *	+-----------------------------------+
 *	|    iv     |   index   | free -->  |
 *	+-----------+-----------------------+
 *	|	 F R E E A R E A            |
 *	+-----------------------------------+
 *	|              <-- free |   item    |
 *	+-----------------------------------+
 *	|   item    |   item    |   item    |
 *	+-----------------------------------+
 *
 * sizeof(PAGE) == 26 bytes + possibly 20 bytes of checksum and possibly
 * 16 bytes of IV (+ 2 bytes for alignment), and the following indices
 * are guaranteed to be two-byte aligned.  If we aren't doing crypto or
 * checksumming the bytes are reclaimed for data storage.
 *
 * For hash and btree leaf pages, index items are paired, e.g., inp[0] is the
 * key for inp[1]'s data.  All other types of pages only contain single items.
 */
```

## Page metadata

```c
typedef struct __pg_chksum {
	u_int8_t	unused[2];		/* 26-27: For alignment */
	u_int8_t	chksum[4];		/* 28-31: Checksum */
} PG_CHKSUM;

typedef struct __pg_crypto {
	u_int8_t	unused[2];		/* 26-27: For alignment */
	u_int8_t	chksum[DB_MAC_KEY];	/* 28-47: Checksum */
	u_int8_t	iv[DB_IV_BYTES];	/* 48-63: IV */
	/* !!!
	 * Must be 16-byte aligned for crypto
	 */
} PG_CRYPTO;

typedef	u_int32_t	db_pgno_t;	/* Page number type. */
typedef	u_int16_t	db_indx_t;	/* Page offset type. */

typedef struct _db_page {
	DB_LSN	  lsn;		/* 00-07: Log sequence number. */
	db_pgno_t pgno;		/* 08-11: Current page number. */
	db_pgno_t prev_pgno;	/* 12-15: Previous page number. */
	db_pgno_t next_pgno;	/* 16-19: Next page number. */
	db_indx_t entries;	/* 20-21: Number of items on the page. */
	db_indx_t hf_offset;	/* 22-23: High free byte page offset. */

	/*
	 * The btree levels are numbered from the leaf to the root, starting
	 * with 1, so the leaf is level 1, its parent is level 2, and so on.
	 * We maintain this level on all btree pages, but the only place that
	 * we actually need it is on the root page.  It would not be difficult
	 * to hide the byte on the root page once it becomes an internal page,
	 * so we could get this byte back if we needed it for something else.
	 */
#define	LEAFLEVEL	  1
#define	MAXBTREELEVEL	255
	u_int8_t  level;	/*    24: Btree tree level. */
	u_int8_t  type;		/*    25: Page type. */
} PAGE;

/*
 * With many compilers sizeof(PAGE) == 28, while SIZEOF_PAGE == 26.
 * We add in other things directly after the page header and need
 * the SIZEOF_PAGE.  When giving the sizeof(), many compilers will
 * pad it out to the next 4-byte boundary.
 */
#define	SIZEOF_PAGE	26
```
## entry 
Including this here to better understand inp.

```c
/* Get a pointer to the bytes at a specific index. */
// [ page pointer plus dereferenced value of the input index at P_INP + indx. ]
#define	P_ENTRY(dbp, pg, indx)	((u_int8_t *)pg + P_INP(dbp, pg)[indx])
```

## inp

I think **in**dex **p**ointer..?

I'm a little mixed up about the index pointers vs. the items, the index pointers
appear to be at the end of the "metadata" section of the page, from what I
understand, these index "pointers" are really offsets that tell you how far from
the start of the page to go for a given item? E.g. the i'th item is located at
`pg + inp[i]`

Looking back to the chart above, the `inp[]` or `db_indx_t *inp` is, in C dualism, the
array of items in the page or the pointer to the address of the first item in the
page.

This pointer can be calculated from the pointer to the page by pointer
arithmetic,  page pointer + page metadata length = *inp:

I interpret the comment above:

     For hash and btree leaf pages, index items are paired, e.g., inp[0] is the
     key for inp[1]'s data.  All other types of pages only contain single items.

To mean that hash and btree leaf page's have exactly 2 items, (as opposed to an
even number of k-v items)  and all other pages only have a single item.

```c
/*
 * !!!
 * DB_AM_ENCRYPT always implies DB_AM_CHKSUM so that must come first.
 */
#define	P_INP(dbp, pg)							\
	((db_indx_t *)((u_int8_t *)(pg) + SIZEOF_PAGE +			\
	(F_ISSET((dbp), DB_AM_ENCRYPT) ? sizeof(PG_CRYPTO) :		\
	(F_ISSET((dbp), DB_AM_CHKSUM) ? sizeof(PG_CHKSUM) : 0))))

// [ Presumably F_ISSET(dbp, flag) checks to see if some flag is set in the
//   metadata of the db or the tree. ]
```

### `__db_vrfy_inpitem()`

Used in the `db_verify` tool, when looping through each page, each individual
item inside is handed off to `__db_vrfy_inpitem()` for verification:

```c
/*
 * __db_vrfy_inpitem --
 *	Verify that a single entry in the inp array is sane, and update
 *	the high water mark and current item offset.  (The former of these is
 *	used for state information between calls, and is required;  it must
 *	be initialized to the pagesize before the first call.)
 *
 *	Returns DB_VERIFY_FATAL if inp has collided with the data,
 *	since verification can't continue from there;  returns DB_VERIFY_BAD
 *	if anything else is wrong.
 *
 * PUBLIC: int __db_vrfy_inpitem __P((DB *, PAGE *,
 * PUBLIC:     db_pgno_t, u_int32_t, int, u_int32_t, u_int32_t *, u_int32_t *));
 */
int
__db_vrfy_inpitem(dbp, h, pgno, i, is_btree, flags, himarkp, offsetp)
	DB *dbp;
	PAGE *h;
	db_pgno_t pgno;
	u_int32_t i; // [ presumably the index in the inp array that we are looking
                 //   at. ]
	int is_btree;
	u_int32_t flags, *himarkp, *offsetp;
{
	BKEYDATA *bk;
	ENV *env;
	db_indx_t *inp, offset, len;

	env = dbp->env;

	DB_ASSERT(env, himarkp != NULL);
	inp = P_INP(dbp, h);

    // [ I believe beginnning in the comment below refers more generally to the
    //   direction which the inp grows, it does not grow from the "beginning of the
    //   page" but rather "from the direction of the beginning of the page toward the
    //   end." ]
	/*
	 * Check that the inp array, which grows from the beginning of the
	 * page forward, has not collided with the data, which grow from the
	 * end of the page backward.
	 */
    // [ Don't know what himarkp is yet, but according to comments above, it is
    //   initialized to the pagesize before the first call (of this function
    //   presumably. So at the first call the right side of this comparison is
    //   the beginning of the page + the size of the page, or h[*himarkp]. so it
    //   is a pointer to one past the size of the page. ]
	if (inp + i >= (db_indx_t *)((u_int8_t *)h + *himarkp)) {
		/* We've collided with the data.  We need to bail. */
		EPRINT((env, DB_STR_A("0563",
		    "Page %lu: entries listing %lu overlaps data",
		    "%lu %lu"), (u_long)pgno, (u_long)i));
		return (DB_VERIFY_FATAL);
	}

    // [ Kind of confirms what I discussed above, the inp is really an array of
    //   offsets to page entries from the beginning of the page, this is the
    //   offset of the inp we are looking at right now. ]
	offset = inp[i];

	/*
	 * Check that the item offset is reasonable:  it points somewhere
	 * after the inp array and before the end of the page.
	 */
	if (offset <= INP_OFFSET(dbp, h, i) || offset >= dbp->pgsize) {
		EPRINT((env, DB_STR_A("0564",
		    "Page %lu: bad offset %lu at page index %lu",
		    "%lu %lu %lu"), (u_long)pgno, (u_long)offset, (u_long)i));
		return (DB_VERIFY_BAD);
	}

	/* Update the high-water mark (what HOFFSET should be) */
	if (offset < *himarkp)
		*himarkp = offset;

	if (is_btree) {
		/*
		 * Check alignment;  if it's unaligned, it's unsafe to
		 * manipulate this item.
		 */
		if (offset != DB_ALIGN(offset, sizeof(u_int32_t))) {
			EPRINT((env, DB_STR_A("0565",
			    "Page %lu: unaligned offset %lu at page index %lu",
			    "%lu %lu %lu"), (u_long)pgno, (u_long)offset,
			    (u_long)i));
			return (DB_VERIFY_BAD);
		}

		/*
		 * Check that the item length remains on-page.
		 */
		bk = GET_BKEYDATA(dbp, h, i);

		/*
		 * We need to verify the type of the item here;
		 * we can't simply assume that it will be one of the
		 * expected three.  If it's not a recognizable type,
		 * it can't be considered to have a verifiable
		 * length, so it's not possible to certify it as safe.
		 */
		switch (B_TYPE(bk->type)) {
		case B_KEYDATA:
			len = bk->len;
			break;
		case B_DUPLICATE:
		case B_OVERFLOW:
			len = BOVERFLOW_SIZE;
			break;
		default:
			EPRINT((env, DB_STR_A("0566",
			    "Page %lu: item %lu of unrecognizable type",
			    "%lu %lu"), (u_long)pgno, (u_long)i));
			return (DB_VERIFY_BAD);
		}

		if ((size_t)(offset + len) > dbp->pgsize) {
			EPRINT((env, DB_STR_A("0567",
			    "Page %lu: item %lu extends past page boundary",
			    "%lu %lu"), (u_long)pgno, (u_long)i));
			return (DB_VERIFY_BAD);
		}
	}

	if (offsetp != NULL)
		*offsetp = offset;
	return (0);
}
```

## Entries



