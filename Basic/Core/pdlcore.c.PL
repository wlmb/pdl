# Create pdlcore.c
# - needed for bad-value handling in whichdatatype

use strict;

use Config;
use File::Basename qw(&basename &dirname);

require './Dev.pm'; PDL::Core::Dev->import;
PDL::Core::Dev::loadmod_Types();
PDL::Types->import(':All');

# This forces PL files to create target in same directory as PL file.
# This is so that make depend always knows where to find PL derivatives.
chdir(dirname($0));
my $file;
($file = basename($0)) =~ s/\.PL$//;
$file =~ s/\.pl$//
    if ($Config{'osname'} eq 'VMS' or
        $Config{'osname'} eq 'OS2');  # "case-forgiving"

print "Extracting $file\n";

open OUT,">$file" or die "Can't create $file: $!";
chmod 0644, $file;

print OUT <<"!WITH!SUBS!";

/* pdlcore.c - generated automatically by pdlcore.c.PL */

!WITH!SUBS!


print OUT <<'!HEADER!';
#undef FOODEB
#include "pdl.h"      /* Data structure declarations */
#define PDL_IN_CORE /* access funcs directly not through PDL-> */
#include "pdlcore.h"  /* Core declarations */


/* Needed to get badvals from the Core structure (in pdl_avref_<type>) */
extern Core PDL; 

#include <math.h> /* for isfinite */
!HEADER!


##############################
# PDL handling stuff starts here
#
print OUT <<'!NO!SUBS!'
static SV *getref_pdl(pdl *it) {
        SV *newref;
        if(!it->sv) {
                SV *ref;
                HV *stash = gv_stashpv("PDL",TRUE);
                SV *psv = newSViv(PTR2IV(it));
                it->sv = psv;
                newref = newRV_noinc(it->sv);
                (void)sv_bless(newref,stash);
        } else {
                newref = newRV_inc(it->sv);
                SvAMAGIC_on(newref);
        }
        return newref;
}

void pdl_SetSV_PDL ( SV *sv, pdl *it ) {
        SV *newref = getref_pdl(it); /* YUCK!!!! */
        sv_setsv(sv,newref);
        SvREFCNT_dec(newref);
}


/* Size of data type information */

size_t pdl_howbig (int datatype) {
    switch (datatype) {

!NO!SUBS!
  ;
# generate the cases for the various types

for my $type (types()) {
   my ($sym,$ctype) = map $type->$_, qw/sym ctype/;
   print OUT << "!WITH!SUBS!";
    case $sym:
      return sizeof($ctype);
!WITH!SUBS!
}

print OUT sprintf qq{#line %d "%s"\n}, __LINE__ + 2,  __FILE__;
print OUT <<'!NO!SUBS!';

    default:
      croak("Unknown datatype code = %d",datatype);
    }
}

/* Make a scratch dataspace for a scalar pdl */

void pdl_makescratchhash(pdl *ret, PDL_Anyval data) {
  STRLEN n_a;
  HV *hash;
  SV *dat; PDL_Indx fake[1];
  
  /* Compress to smallest available type.  */
  ret->datatype = data.type;

  /* Create a string SV of apropriate size.  The string is arbitrary
   * and just has to be larger than the largest datatype.   */
  dat = newSVpvn("                                ",pdl_howbig(ret->datatype));
  
  ret->data = SvPV(dat,n_a);
  ret->datasv = dat;
  /* Refcnt should be 1 already... */
    
  /* Make the whole pdl mortal so destruction happens at the right time.
   * If there are dangling references, pdlapi.c knows not to actually
   * destroy the C struct. */
  sv_2mortal(getref_pdl(ret));
  
  pdl_setdims(ret, fake, 0); /* 0 dims in a scalar */
  ret->nvals = 1;            /* 1 val  in a scalar */
  
  /* NULLs should be ok because no dimensions. */
  pdl_set(ret->data, ret->datatype, NULL, NULL, NULL, 0, 0, data);
  
}


/*
  "Convert" a perl SV into a pdl (alright more like a mapping as
   the data block is not actually copied in the most common case
   of a single scalar) scalars are automatically converted to PDLs.
*/

pdl* pdl_SvPDLV ( SV* sv ) {

   pdl* ret;
   PDL_Indx fake[1];
   SV *sv2;

   if ( !SvROK(sv) ) {
      /* The scalar is not a ref, so we can use direct conversion. */
      PDL_Anyval data;
      ret = pdl_create(PDL_PERM);  /* Scratch pdl */
      /* Scratch hash for the pdl :( - slow but safest. */
      ANYVAL_FROM_SV(data, sv, TRUE, -1);
      pdl_makescratchhash(ret, data);
      return ret;
   } /* End of scalar case */

   if(sv_derived_from(sv, "Math::Complex")) {
      dSP;
      int count, i;
      NV retval;
      double vals[2];
      char *meths[] = { "Re", "Im" };
      PDL_Anyval data;
      ENTER; SAVETMPS;
      for (i = 0; i < 2; i++) {
        PUSHMARK(sp); XPUSHs(sv); PUTBACK;
        count = perl_call_method(meths[i], G_SCALAR);
        SPAGAIN;
        if (count != 1) croak("Failed Math::Complex method '%s'", meths[i]);
        retval = POPn;
        vals[i] = (double)retval;
        PUTBACK;
      }
      FREETMPS; LEAVE;
      ret = pdl_create(PDL_PERM);  /* Scratch pdl */
      data.type = PDL_CD;
      data.value.C = (PDL_CDouble)(vals[0] + I * vals[1]);
      pdl_makescratchhash(ret, data);
      return ret;
   }

   /* If execution reaches here, then sv is NOT a scalar
    * (i.e. it is a ref).
    */

   if(SvTYPE(SvRV(sv)) == SVt_PVHV) {
        HV *hash = (HV*)SvRV(sv);
        SV **svp = hv_fetchs(hash,"PDL",0);
        if(svp == NULL) {
                croak("Hash given as a pdl (%s) - but not {PDL} key!", sv_reftype(SvRV(sv), TRUE));
        }
        if(*svp == NULL) {
                croak("Hash given as a pdl (%s) - but not {PDL} key (*svp)!", sv_reftype(SvRV(sv), TRUE));
        }

        /* This is the magic hook which checks to see if {PDL}
        is a code ref, and if so executes it. It should
        return a standard ndarray. This allows
        all kinds of funky objects to be derived from PDL,
        and allow normal PDL functions to still work so long
        as the {PDL} code returns a standard ndarray on
        demand - KGB */

        if (SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVCV) {
           dSP;
           int count;
           ENTER ;
           SAVETMPS ;
           PUSHMARK(sp) ;

           count = perl_call_sv(*svp, G_SCALAR|G_NOARGS);

           SPAGAIN ;

           if (count != 1)
              croak("Execution of PDL structure failed to return one value\n") ;

           sv=newSVsv(POPs);

           PUTBACK ;
           FREETMPS ;
           LEAVE ;
        }
        else {
           sv = *svp;
        }

        if(SvGMAGICAL(sv)) {
                mg_get(sv);
        }

        if ( !SvROK(sv) ) {   /* Got something from a hash but not a ref */
                croak("Hash given as pdl - but PDL key is not a ref!");
        }
    }
      
    if(SvTYPE(SvRV(sv)) == SVt_PVAV) {
        /* This is similar to pdl_avref in Core.xs.PL -- we do the same steps here. */
        AV *dims, *av;
        int i, depth; 
        int datalevel = -1;
        pdl *p;

        av = (AV *)SvRV(sv);
        dims = (AV *)sv_2mortal((SV *)newAV());
        av_store(dims,0,newSViv( (IV) av_len(av)+1 ) );
        
        /* Pull sizes using av_ndcheck */
        depth = 1 + av_ndcheck(av,dims,0,&datalevel);

        return pdl_from_array(av, dims, -1, NULL); /* -1 means pdltype autodetection */

    } /* end of AV code */
    
    if (SvTYPE(SvRV(sv)) != SVt_PVMG)
      croak("Error - tried to use an unknown data structure as a PDL");
    else if( !( sv_derived_from( sv, "PDL") ) )
      croak("Error - tried to use an unknown Perl object type as a PDL");

    sv2 = (SV*) SvRV(sv);

    /* Return the pdl * pointer */
    ret = INT2PTR(pdl *, SvIV(sv2));

    /* Final check -- make sure it has the right magic number */
    if(ret->magicno != PDL_MAGICNO) {
        croak("Fatal error: argument is probably not an ndarray, or\
 magic no overwritten. You're in trouble, guv: %p %p %lu\n",sv2,ret,ret->magicno);
   }

   return ret;
}

/* Make a new pdl object as a copy of an old one and return - implement by
   callback to perl method "copy" or "new" (for scalar upgrade) */

SV* pdl_copy( pdl* a, char* option ) {

   SV* retval;
   char meth[20];

   dSP ;   int count ;

   retval = newSVpv("",0); /* Create the new SV */

   ENTER ;   SAVETMPS ;   PUSHMARK(sp) ;

   /* Push arguments */

#ifdef FOOBAR
   if (sv_isobject((SV*)a->hash)) {
#endif
       XPUSHs(sv_2mortal(getref_pdl(a)));
       strcpy(meth,"copy");
       XPUSHs(sv_2mortal(newSVpv(option, 0))) ;
#ifdef FOOBAR
   }
   else{
       XPUSHs(perl_get_sv("PDL::name",FALSE)); /* Default object */
       XPUSHs(sv_2mortal(getref_pdl(a)));
       strcpy(meth,"new");
   }
#endif

   PUTBACK ;

   count = perl_call_method(meth, G_SCALAR); /* Call Perl */

   SPAGAIN;

   if (count !=1)
      croak("Error calling perl function\n");

   sv_setsv( retval, POPs ); /* Save the perl returned value */

   PUTBACK ;   FREETMPS ;   LEAVE ;

   return retval;
}



/* Pack dims array - returns dims[] (pdl_smalloced) and ndims */

PDL_Indx* pdl_packdims ( SV* sv, PDL_Indx *ndims ) {

   SV*  bar;
   AV*  array;
   PDL_Indx i;
   PDL_Indx *dims;

   if (!(SvROK(sv) && SvTYPE(SvRV(sv))==SVt_PVAV))  /* Test */
       return NULL;

   array = (AV *) SvRV(sv);   /* dereference */

   *ndims = (PDL_Indx) av_len(array) + 1;  /* Number of dimensions */

   dims = (PDL_Indx *) pdl_smalloc( (*ndims) * sizeof(*dims) ); /* Array space */
   if (dims == NULL)
      croak("Out of memory");

   for(i=0; i<(*ndims); i++) {
      bar = *(av_fetch( array, i, 0 )); /* Fetch */
      dims[i] = (PDL_Indx) SvIV(bar);
   }
   return dims;
}

/* unpack dims array into PDL SV* */

void pdl_unpackdims ( SV* sv, PDL_Indx *dims, PDL_Indx ndims ) {

   AV*  array;
   HV* hash;
   PDL_Indx i;

   hash = (HV*) SvRV( sv );
   array = newAV();
   (void)hv_store(hash, "Dims", strlen("Dims"), newRV( (SV*) array), 0 );

   if (ndims==0 )
      return;

   for(i=0; i<ndims; i++)
         av_store( array, i, newSViv( (IV)dims[i] ) );
}

PDL_Indx pdl_safe_indterm( PDL_Indx dsz, PDL_Indx at, char *file, int lineno)
{
  if (!(at >= 0 && at < dsz))
    pdl_pdl_barf("access [%d] out of range [0..%d] (inclusive) at %s line %d",
          at, dsz-1, file?file:"?", lineno);
  return at;
}

/*
   pdl_smalloc - utility to get temporary memory space. Uses
   a mortal *SV for this so it is automatically freed when the current
   context is terminated without having to call free(). Naughty but
   nice!
*/


void* pdl_smalloc ( STRLEN nbytes ) {
    STRLEN n_a;
   SV* work;

   work = sv_2mortal(newSVpv("", 0));

   SvGROW( work, nbytes);

   return (void *) SvPV(work, n_a);
}

/*********** Stuff for barfing *************/
/*
   This routine barfs/warns in a thread-safe manner. If we're in the main thread,
   this calls the perl-level barf/warn. If in a worker thread, we save the
   message to barf/warn in the main thread later
   For greppability: this is where pdl_pdl_barf and pdl_pdl_warn are defined
*/

static void pdl_barf_or_warn(const char* pat, int iswarn, va_list* args)
{
    /* If we're in a worker thread, we queue the
     * barf/warn for later, and exit the thread ...
     */
    if( pdl_pthread_barf_or_warn(pat, iswarn, args) )
        return;

    /* ... otherwise we fall through and barf by calling
     * the perl-level PDL::barf() or PDL::cluck()
     */

    { /* scope block for C89 compatibility */

        SV * sv;

        dSP;
        ENTER;
        SAVETMPS;
        PUSHMARK(SP);

        sv = sv_2mortal(newSV(0));
        sv_vsetpvfn(sv, pat, strlen(pat), args, Null(SV**), 0, Null(bool*));
        va_end(*args);

        XPUSHs(sv);

        PUTBACK;

        call_pv(iswarn ? "PDL::cluck" : "PDL::barf", G_DISCARD);

        FREETMPS;
        LEAVE;
    } /* end C89 compatibility scope block */
}

#define GEN_PDL_BARF_OR_WARN_I_STDARG(type, iswarn)     \
    void pdl_pdl_##type(const char* pat, ...)           \
    {                                                   \
        va_list args;                                   \
        va_start(args, pat);                            \
        pdl_barf_or_warn(pat, iswarn, &args);           \
    }

GEN_PDL_BARF_OR_WARN_I_STDARG(barf, 0)
GEN_PDL_BARF_OR_WARN_I_STDARG(warn, 1)


/**********************************************************************
 *
 * CONSTRUCTOR/INGESTION HELPERS
 *
 * The following routines assist with the permissive constructor,
 * which is designed to build a PDL out of basically anything thrown at it.
 *
 * They are all called by pdl_avref in Core.xs, which in turn is called by the constructors
 * in Core.pm.PL.  The main entry point is pdl_from_array(), which calls 
 * av_ndcheck() to identify the necessary size of the output PDL, and then dispatches
 * the copy into pdl_setav_<type> according to the type of the output PDL.
 *
 */

/******************************
 * av_ndcheck -
 *  traverse a Perl array ref recursively, following down any number of
 *  levels of references, and generate a minimal PDL dim list that can
 *  encompass them all according to permissive-constructor rules.
 *
 *  Scalars, array refs, and PDLs may be mixed in the incoming AV.
 *
 *  The routine works out the dimensions of a corresponding
 *  ndarray (in the AV dims) in reverse notation (vs PDL conventions).
 *
 *  It does not enforce a rectangular array on the input, the idea being that
 *  omitted values will be set to zero or the undefval in the resulting ndarray,
 *  i.e. we can make ndarrays from 'sparse' array refs.
 *
 *  Empty PDLs are treated like any other dimension -- i.e. their 
 *  0-length dimensions are thrown into the mix just like nonzero 
 *  dimensions would be.
 *
 *  The possible presence of empty PDLs forces us to pad out dimensions
 *  to unity explicitly in cases like
 *         [ Empty[2x0x2], 5 ]
 *  where simple parsing would yield a dimlist of 
 *         [ 2,0,2,2 ]
 *  which is still Empty.
 */

PDL_Indx av_ndcheck(AV* av, AV* dims, int level, int *datalevel)
{
  PDL_Indx i, len, oldlen;
  int newdepth, depth = 0;
  int n_scalars = 0;
  SV *el, **elp;
  pdl *dest_pdl;           /* Stores PDL argument */

  if(dims==NULL) {
    pdl_pdl_barf("av_ndcheck - got a null dim array! This is a bug in PDL.");
  }

  /* Start with a clean slate */
   if(level==0) {
    av_clear(dims);
  }

  len = av_len(av);                         /* Loop over elements of the AV */
  for (i=0; i<= len; i++) {
    
    newdepth = 0;                           /* Each element - find depth */
    elp = av_fetch(av,i,0);
    
    el = elp ? *elp : 0;                    /* Get the ith element */
    if (el && SvROK(el)) {                  /* It is a reference */
      if (SvTYPE(SvRV(el)) == SVt_PVAV) {   /* It is an array reference */
        
        /* Recurse to find depth inside the array reference */
        newdepth = 1 + av_ndcheck((AV *) SvRV(el), dims, level+1, datalevel);
        
      } else if ( (dest_pdl = pdl_SvPDLV(el)) ) {
        /* It is a PDL - walk down its dimension list, exactly as if it
         * were a bunch of nested array refs.  We pull the ndims and dims
         * fields out to local variables so that nulls can be treated specially.
         */
        int j;
        short pndims;
        PDL_Indx *pdims;
        PDL_Indx pnvals;
        
        pdl_make_physdims(dest_pdl);
        
        pndims = dest_pdl->ndims;
        pdims = dest_pdl->dims;
        pnvals = dest_pdl->nvals;
        
        for(j=0;j<pndims;j++) {
          int jl = pndims-j+level;
          
          PDL_Indx siz = pdims[j];
          
          if(  av_len(dims) >= jl &&
               av_fetch(dims,jl,0) != NULL &&
               SvIOK(*(av_fetch(dims,jl,0)))) {
            
            /* We have already found something that specifies this dimension -- so */ 
            /* we keep the size if possible, or enlarge if necessary.              */
            oldlen=(PDL_Indx)SvIV(*(av_fetch(dims,jl,0)));
            if(siz > oldlen) {
              sv_setiv(*(av_fetch(dims,jl,0)),(IV)(pdims[j]));
            }
            
          } else {
            /* Breaking new dimensional ground here -- if this is the first element */
            /* in the arg list, then we can keep zero elements -- but if it is not  */
            /* the first element, we have to pad zero dims to unity (because the    */
            /* prior object had implicit size of 1 in all implicit dimensions)      */
            av_store(dims, jl, newSViv((IV)(siz?siz:(i?1:0))));
          }
        }
        
        /* We have specified all the dims in this PDL.  Now pad out the implicit */
        /* dims of size unity, to wipe out any dims of size zero we have already */
        /* marked. */
        
        for(j=pndims+1; j <= av_len(dims); j++) {
          SV **svp = av_fetch(dims,j,0);

          if(!svp){
            av_store(dims, j, newSViv((IV)1));
          } else if( (int)SvIV(*svp) == 0 ) {
            sv_setiv(*svp, (IV)1);
          }
        }
        
        newdepth= pndims;
        
      } else {
        croak("av_ndcheck: non-array, non-PDL ref in structure\n\t(this is usually a problem with a pdl() call)");
      }

    } else { 
      /* got a scalar (not a ref) */
      n_scalars++;

    }

      if (newdepth > depth)
        depth = newdepth;
  }
  
  len++; // convert from funky av_len return value to real count
  
    if (av_len(dims) >= level && av_fetch(dims, level, 0) != NULL
      && SvIOK(*(av_fetch(dims, level, 0)))) {
    oldlen = (PDL_Indx) SvIV(*(av_fetch(dims, level, 0)));
    
    if (len > oldlen)
      sv_setiv(*(av_fetch(dims, level, 0)), (IV) len);
    }
    else
      av_store(dims,level,newSViv((IV) len));
  
  /* We found at least one element -- so pad dims to unity at levels earlier than this one */
  if(n_scalars) {
    for(i=0;i<level;i++) {
      SV **svp = av_fetch(dims, i, 0);
      if(!svp) {
        av_store(dims, i, newSViv((IV)1));
      } else if( (PDL_Indx)SvIV(*svp) == 0) {
        sv_setiv(*svp, (IV)1);
      }
    }
    
    for(i=level+1; i <= av_len(dims); i++) {
      SV **svp = av_fetch(dims, i, 0);
      if(!svp) {
        av_store(dims, i, newSViv((IV)1));
      } else if( (PDL_Indx)SvIV(*svp) == 0) {
        sv_setiv(*svp, (IV)1);
      }
    }
  }

  return depth;
}

/* helper function used in pdl_from_array */
static int _detect_datatype(AV *av) {
  SV **item;
  AV *array;
  int count, i;
  if (!av) return PDL_D;
  count = av_len(av);
  for (i = 0; i < count; i++) {
    item = av_fetch(av, i, 0);
    if (*item) {
      if (SvROK(*item)) {
        array = (AV*)SvRV(*item);
        if (_detect_datatype(array) == PDL_D) {
          return PDL_D;
        }
      }
      if (SvOK(*item) && !SvIOK(*item)) {
        return PDL_D;
      }
    }
  }
#if IVSIZE == 8
  return PDL_LL;
#else
  return PDL_L;
#endif
}

/**********************************************************************
 * pdl_from_array - dispatcher gets called only by pdl_avref (defined in
 * Core.xs) - it breaks out to pdl_setav_<type>, below, based on the 
 * type of the destination PDL.
 */
pdl* pdl_from_array(AV* av, AV* dims, int type, pdl* p)
{
  int ndims, i, level=0;
  PDL_Indx *pdims;
  PDL_Anyval undefval = { -1, 0 };

  ndims = av_len(dims)+1;
  pdims = (PDL_Indx *) pdl_smalloc( (ndims) * sizeof(*pdims) );
  for (i=0; i<ndims; i++) {
     pdims[i] = SvIV(*(av_fetch(dims, ndims-1-i, 0))); /* reverse order */
  }

  if (p == NULL)
     p = pdl_create(PDL_PERM);
  pdl_setdims (p, pdims, ndims);
  if (type == -1) {
    type = _detect_datatype(av);
  }
  p->datatype = type;
  pdl_allocdata (p);
  pdl_make_physical(p);

  /******
   * Copy the undefval to fill empty spots in the ndarray...
   */
  ANYVAL_FROM_SV(undefval, NULL, TRUE, type);

  switch (type) {
!NO!SUBS!

##########
# Perl snippet autogenerates switch statement to distribute
# pdl_setav calls...
#
  for my $t (types()) {
    my ($type, $t2, $ppsym) = map $t->$_, qw(sym shortctype ppsym);
    print OUT sprintf qq{#line %d "%s"\n}, __LINE__ + 2,  __FILE__;
    print OUT <<"!WITH!SUBS!";
  case $type:
    pdl_setav_$t2(p->data,av,pdims,ndims,level, undefval.value.$ppsym, p);
    break;

!WITH!SUBS!

  }
#
# Back to your regularly scheduled C code emission...
########

  print OUT sprintf qq{#line %d "%s"\n}, __LINE__ + 2,  __FILE__;
  print OUT <<'!NO!SUBS!';
  default:
    croak("pdl_from_array: internal error: got type %d",type);
    break;
  }
  p->state &= ~PDL_NOMYDIMS;
  return p;
}

/*
 * pdl_kludge_copy_<type>  - copy a PDL into a part of a being-formed PDL.
 * It is only used by pdl_setav_<type>, to handle the case where a PDL is part
 * of the argument list. 
 *
 * kludge_copy recursively walks down the dim list of both the source and dest
 * pdls, copying values in as we go.  It differs from PP copy in that it operates
 * on only a portion of the output pdl.
 *
 * (If I were Lazier I would have popped up into the perl level and used threadloops to
 * assign to a slice of the output pdl -- but this is probably a little faster.)
 *
 * -CED 17-Jun-2004
 *
 * Arguments:
 * poff  is an integer indicating which element along the current direction is being treated (for padding accounting)
 * pdata is a pointer into the destination PDL's data;
 * pdims is a pointer to the destination PDL's dim list;
 * ndims is the size of the destination PDL's dimlist;
 * level is the conjugate dimension along which copying is happening (indexes pdims).
 *    "conjugate" means that it counts backward through the dimension array.
 * stride is the increment in the data array corresponding to this dimension;
 *
 * pdl is the input PDL.
 * plevel is the dim number for the input PDL, which works in the same sense as level.
 *   It is offset to account for the difference in dimensionality between the input and
 *   output PDLs. It is allowed to be negative (which is equivalent to the "permissive
 *   slicing" that treats missing dimensions as present and having size 1), but should
 *   not match or exceed pdl->ndims. 
 * pptr is the current offset data pointer into pdl->data.
 *
 * Kludge-copy works backward through the dim lists, so that padding is simpler:  if undefval
 * padding is required at any particular dimension level, the padding occupies a contiguous
 * block of memory.
 */
!NO!SUBS!

for my $type ( map $_->shortctype, types() ) {

print OUT sprintf qq{#line %d "%s"\n}, __LINE__ + 2,  __FILE__;
print OUT <<"!WITH!SUBS!";

PDL_Indx pdl_kludge_copy_$type(PDL_Indx poff, // Offset into the dest data array
                           PDL_$type* pdata,  // Data pointer in the dest data array
                           PDL_Indx* pdims,   // Pointer to the dimlist for the dest pdl
                           PDL_Indx ndims,         // Number of dimensions in the dest pdl
                           int level,         // Recursion level
                           PDL_Indx stride,   // Stride through memory for the current dim
                           pdl* source_pdl,   // pointer to the source pdl
                           int plevel,        // level within the source pdl
                           void* pptr,        // Data pointer in the source pdl
                           PDL_$type undefval, // undefval for the dest pdl
                           pdl* p              // pointer to the dest pdl
                           ) {
  PDL_Indx i;
  PDL_Indx undef_count = 0;

  /* Can't copy into a level deeper than the number of dims in the output PDL */
  if(level > ndims ) {
    fprintf(stderr,"pdl_kludge_copy: level=%d; ndims=%"IND_FLAG"\\n",level,ndims);
    croak("Internal error - please submit a bug report at https://github.com/PDLPorters/pdl/issues:\\n  pdl_kludge_copy: Assertion failed; ndims-1-level (%"IND_FLAG") < 0!.",ndims-1-level);
  }

  if(level >= ndims - 1) {
    /* We are in as far as we can go in the destination PDL, so direct copying is in order. */
    int pdldim = source_pdl->ndims - 1 - plevel;  // which dim are we working in the source PDL?
    PDL_Indx pdlsiz;
    int oob = (ndims-1-level < 0);         // out-of-bounds flag

    /* Do bounds checking on the source dimension -- if we wander off the end of the 
     * dimlist, we are doing permissive-slicing kind of stuff (not enough dims in the 
     * source to fully account for the output dimlist); if we wander off the beginning, we
     * are doing dimensional padding.  In either case, we just iterate once.
     */
    if(pdldim < 0 || pdldim >= source_pdl->ndims) {
      pdldim = (pdldim < 0) ? (0) : (source_pdl->ndims - 1);
      pdlsiz = 1;
    } else {
      pdlsiz = source_pdl->dims[pdldim];
    }

    /* This is used inside the switch in order to detect badvalues. */
    PDL_Anyval source_badval = PDL.get_pdl_badvalue(source_pdl);

    /* This is the actual data-copying code. It is generated with a Perl loop, to
     * ensure that all current PDL types get treated. */

    switch(source_pdl->datatype) {
!WITH!SUBS!

        # perl loop to emit code for all the PDL types -- ctype gets the C type of 
        # the source PDL, switch_type gets the Perl name, ppsym gets
        # the symbol need to retrieve from a PDL_Anyval, and type_usenan is a
        # boolean indicating whether this type handles NaNs.
        foreach my $inner_type ( types() ) {
	    my $switch_type = $inner_type->sym;
	    my $ctype = $inner_type->ctype;
	    my $stype = $inner_type->shortctype;
	    my $ppsym = $inner_type->ppsym;

	    my $comp_for_nan =
	          $inner_type->usenan
	          # if not equal, check if both are NaN
	        ? '('.$inner_type->isnan("(($ctype *)pptr)[i]") .' && '.$inner_type->isnan("source_badval.value.$ppsym").')'
	          # otherwise it must be false
	        : '0';

        print OUT sprintf qq{#line %d "%s"\n}, __LINE__ + 2,  __FILE__;
        print OUT <<"!WITH!SUBS!";

      case ${switch_type}:
           /* copy data (unless the source pointer is null) */
      i=0;
      if(pptr && pdata && pdlsiz) {
        for(; i<pdlsiz; i++) {
          if(source_pdl->has_badvalue || (source_pdl->state & PDL_BADVAL)) {
              /* Retrieve directly from .value.* instead of using ANYVAL_EQ_ANYVAL */
              if( (($ctype *)pptr)[i] == source_badval.value.$ppsym || $comp_for_nan ) {
                  /* bad value in source PDL -- use our own type's bad value instead */
                  pdata[i] = PDL.bvals.$type;
                  p->state |= PDL_BADVAL;
              } else {
                  pdata[i] = (PDL_$type) ((${ctype} *)pptr)[i];
              }
          } else {
            pdata[i] = (PDL_$type) ((${ctype} *)pptr)[i];
          }
        } // end of loop over pdlsiz
      } else { 
        // pptr or pdata or pdlsiz are 0
        if(pdata) 
          pdata[i] = undefval;
      }
        /* pad out, in the innermost dimension */
      if( !oob ) {
        for(;  i< pdims[0]-poff; i++) {
          undef_count++;
          pdata[i] = undefval;
        }
      }

      break;
!WITH!SUBS!

        } # end of foreach in the perl generator code

      print OUT sprintf qq{#line %d "%s"\n}, __LINE__ + 2,  __FILE__;
      print OUT <<"!WITH!SUBS!";
    default:
      croak("Internal error - please submit a bug report at https://github.com/PDLPorters/pdl/issues:\\n  pdl_kludge_copy: unknown datatype of %d.",(int)(source_pdl->datatype));
      break;
    }

    return undef_count;
  }

  /* If we are here, we are not at the bottom level yet.  So walk
   *  across this dim and handle copying one dim deeper via recursion.
   *  The loop is placed in a convenience block so we can define the 
   *  dimensional boundscheck flag -- that avoids having to evaluate the complex 
   *  ternary expression for every loop iteration.
   */
  {
      PDL_Indx limit =  (   
          (plevel >= 0 && 
           (source_pdl->ndims - 1 - plevel >= 0)
          )   
          ?   (source_pdl->dims[ source_pdl->ndims-1-plevel ])   
          :   1    
          );
      for(i=0; i < limit ; i++) {
          undef_count += pdl_kludge_copy_$type(0, pdata + stride * i,
                                               pdims,
                                               ndims,
                                               level+1,
                                               stride / ((pdims[ndims-2-level]) ? (pdims[ndims-2-level]) : 1),
                                               source_pdl,
                                               plevel+1,
                                               ((PDL_Byte *) pptr) + source_pdl->dimincs[source_pdl->ndims-1-plevel] * i * pdl_howbig(source_pdl->datatype),
                                               undefval,
                                               p
              );
      } /* end of kludge_copy recursion loop */
  } /* end of recursion convenience block */

  /* pad the rest of this dim to zero if there are not enough elements in the source PDL... */
  if(i < pdims[ndims - 1 - level]) {
      int cursor, target;

      cursor = i * stride;
      target = pdims[ndims-1-level]*stride;
      undef_count += target - cursor;

      for(;
          cursor < target;
          cursor++) {
          pdata[cursor] = undefval;
      }

  } /* end of padding IF statement */

  return undef_count;
}

/*
 * pdl_setav_<type> loads a new PDL with values from a Perl AV, another PDL, or
 * a mix of both.  Heterogeneous sizes are handled by padding the new PDL's
 * values out to size with the undefval.  It is only called by pdl_setav in Core.XS,
 * via the trampoline pdl_from_array just above. pdl_from_array dispatches execution
 * to pdl_setav_<type> according to the type of the destination PDL. 
 *
 * The code is complicated by the "bag-of-stuff" nature of AVs.  We handle 
 * Perl scalars, AVs, *and* PDLs (via pdl_kludge_copy).
 * 
 *   -  pdata is the data pointer from a PDL
 *   -  av is the array ref (or PDL) to use to fill the data with,
 *   -  pdims is the dimlist
 *   -  ndims is the size of the dimlist
 *   -  level is the recursion level, which is also the dimension that we are filling
 */

PDL_Indx pdl_setav_$type(PDL_$type* pdata, AV* av,
                     PDL_Indx* pdims, int ndims, int level, PDL_$type undefval, pdl *p)
{
  PDL_Indx cursz = pdims[ndims-1-level]; /* we go from the highest dim inward */
  PDL_Indx len = av_len(av);
  PDL_Indx i,stride=1;

  SV *el, **elp;
  PDL_Indx undef_count = 0;

  for (i=0;i<ndims-1-level;i++) {
    stride *= pdims[i];
  }

  for (i=0;i<=len;i++,pdata += stride) { /* note len is actually highest index, not element count */

    int foo;

    /* Fetch the next value from the AV */
    elp = av_fetch(av,i,0);
    el = (elp ? *elp : 0);
    foo = el ? SVavref(el) : 0;

    if (foo) {
      /* If the element was an AV ref, recurse to walk through that AV, one dim lower */
      undef_count += pdl_setav_$type(pdata, (AV *) SvRV(el), pdims, ndims, level+1, undefval, p);

    } else if( el && SvROK(el) ) {

      /* If the element was a ref but not an AV, then it should be a PDL */
      pdl *pdl;
      if( (pdl = pdl_SvPDLV(el)) ) {
          /* The element was a PDL - use pdl_kludge_copy to copy it into the destination */
          PDL_Indx pd;
          int pddex;
          
          pdl_make_physical(pdl);
          
          pddex = ndims - 2 - level;
          pd = (pddex >= 0 && pddex < ndims ? pdims[ pddex ] : 0);
          if(!pd)
              pd = 1;
          undef_count += pdl_kludge_copy_$type(0, pdata,pdims,ndims, level+1, stride / pd , pdl, 0, pdl->data, undefval, p);

      } else {
        /* The element is a non-PDL, non-AV ref.  Not allowed. */
        croak("Non-array, non-PDL element in list");
      }
    } else { /* el==0 || SvROK(el)==0: this is a scalar or undef element */
      if( PDL_SV_IS_UNDEF(el) ) {  /* undef case */
        *pdata = (PDL_$type) undefval; 
        undef_count++;

      } else {              /* scalar case */
        if (SvIOK(el)) {
          *pdata = (PDL_$type) SvIV(el);
        } else {
          *pdata = (PDL_$type) SvNV(el);
        }
      }

      /* Pad dim if we are not deep enough */
      if(level < ndims-1) {
        PDL_$type *cursor = pdata;
        PDL_$type *target = pdata + stride;

        for( cursor++;  cursor < target; cursor++ ) {
          *cursor = (PDL_$type)undefval;
          undef_count++;
        }
      }
    }

  } /* end of element loop through the supplied AV */

  /* in case this dim is incomplete set any remaining elements to the undefval */

  if(len < cursz-1 ) {
    PDL_$type *target = pdata + stride * (cursz - 1 - len);
    for( ;
         pdata < target;
         pdata++
         ) {

      *pdata = (PDL_$type) undefval;
      undef_count++;
    }
  }

  /* If the Perl scalar PDL::debug is set, announce padding */
  if(level==0 && undef_count) {
    char debug_flag;
    SV *sv;
    sv = get_sv("PDL::debug",0);
    debug_flag = (PDL_SV_IS_UNDEF(sv)) ? 0 : (char)SvIV(sv);

    if(debug_flag) {
      fflush(stdout);
      fprintf(stderr,"Warning: pdl_setav_$type converted undef to \$PDL::undefval (%g) %ld time%s\\n",(double)undefval,undef_count,undef_count==1?"":"s");
      fflush(stderr);
    }
  }

  return undef_count;
}


!WITH!SUBS!

  } # end type loop
