%module satsolverx

%{

#if defined(SWIGRUBY)
#include "ruby.h"
#include "rubyio.h"
#endif
#include "policy.h"
#include "bitmap.h"
#include "evr.h"
#include "hash.h"
#include "poolarch.h"
#include "pool.h"
#include "poolid.h"
#include "poolid_private.h"
#include "pooltypes.h"
#include "queue.h"
#include "solvable.h"
#include "solver.h"
#include "repo.h"
#include "repo_solv.h"
#include "repo_rpmdb.h"

static const char *
my_id2str( Pool *pool, Id id )
{
  if (id == STRID_NULL)
    return NULL;
  if (id == STRID_EMPTY)
    return "";
  return id2str( pool, id );
}

typedef struct _Relation {
  Offset id;
  Pool *pool;
} Relation;

static Relation *relation_new( Pool *pool, Id id )
{
  if (!id) return NULL;
  Relation *relation = (Relation *)malloc( sizeof( Relation ));
  relation->id = id;
  relation->pool = pool;
  return relation;
}

/* Collection of Relations -> Dependency */
typedef struct _Dependency {
  Offset *relations;               /* ptr to solvable deps (requires, provides, ...)
                                      (offset into repo->idarraydata) */
  Solvable *solvable;              /* solvable this dep belongs to */
} Dependency;

#define DEP_PRV 1
#define DEP_REQ 2
#define DEP_CON 3
#define DEP_OBS 4
#define DEP_REC 5
#define DEP_SUG 6
#define DEP_SUP 7
#define DEP_ENH 8

static Dependency *dependency_new( Solvable *solvable, Offset *relations, int dep )
{
  Dependency *dependency = (Dependency *)malloc( sizeof( Dependency ));
  dependency->solvable = solvable;
  if (relations) {
    dependency->relations = relations;
  }
  else {
    switch( dep ) {
      case DEP_PRV: dependency->relations = &(solvable->provides); break;
      case DEP_REQ: dependency->relations = &(solvable->requires); break;
      case DEP_CON: dependency->relations = &(solvable->conflicts); break;
      case DEP_OBS: dependency->relations = &(solvable->obsoletes); break;
      case DEP_REC: dependency->relations = &(solvable->recommends); break;
      case DEP_SUG: dependency->relations = &(solvable->suggests); break;
      case DEP_SUP: dependency->relations = &(solvable->supplements); break;
      case DEP_ENH: dependency->relations = &(solvable->enhances); break;
      default:
        /* FIXME: raise exception */
	return NULL;
    }
  }
  return dependency;
}

static int dependency_size( const Dependency *dep )
{
  if (!dep) return 0;
  int i = 0;
  if (dep->relations) {
    Id *ids = dep->solvable->repo->idarraydata + *(dep->relations);
    while (*ids++)
      ++i;
  }
  return i;
}


Solvable *solvable_new( Repo *repo, const char *name, const char *evr, const char *arch )
{
  Solvable *s = pool_id2solvable( repo->pool, repo_add_solvable( repo ) );
  Id nameid = str2id( repo->pool, name, 1 );
  Id evrid = str2id( repo->pool, evr, 1 );
  if (arch == NULL) arch = "noarch";
  Id archid = str2id( repo->pool, arch, 1 );
  s->name = nameid;
  s->evr = evrid;
  s->arch = archid;

  /* add self-provides */
  Id rel = rel2id( repo->pool, nameid, evrid, REL_EQ, 1 );
  s->provides = repo_addid_dep( repo, s->provides, rel, 0 );

  return s;
}


typedef struct _Action {
  SolverCmd cmd;
  Id id;
} Action;

static Action *action_new( SolverCmd cmd, Id id )
{
  Action *action = (Action *)malloc( sizeof( Action ));
  action->cmd = cmd;
  action->id = id;
  return action;
}

typedef struct _Transaction {
  Pool *pool;
  Queue queue;
} Transaction;

static Transaction *transaction_new( Pool *pool )
{
  Transaction *t = (Transaction *)malloc( sizeof( Transaction ));
  t->pool = pool;
  queue_init( &(t->queue) );
  return t;
}

static void transaction_free( Transaction *t )
{
  queue_free( &(t->queue) );
  free( t );
}

#define DEC_INSTALL 1
#define DEC_REMOVE 2
#define DEC_UPDATE 3
#define DEC_OBSOLETE 4

typedef struct _Decision {
  int op;               /* DEC_{INSTALL,UPDATE,OBSOLETE,REMOVE} */
  Solvable *solvable;
  Solvable *reason;
} Decision;

static Decision *decision_new( int op, Solvable *solvable, Solvable *reason )
{
  Decision *d = (Decision *)malloc( sizeof( Decision ));
  d->op = op;
  d->solvable = solvable;
  d->reason = reason;
  return d;
}

typedef struct _Problem {
  int reason;
  Solvable *source;
  Relation *relation;
  Solvable *target;
} Problem;

static Problem *problem_new( int reason, Solvable *source, Relation *relation, Solvable *target )
{
  Problem *p = (Problem *)malloc( sizeof( Problem ));
  p->reason = reason;
  p->source = source;
  p->relation = relation;
  p->target = target;
  return p;
}

%}

/*-------------------------------------------------------------*/
/* types and typemaps */

#if defined(SWIGRUBY)
%typemap(in) FILE* {
  OpenFile *fptr;

  Check_Type($input, T_FILE);
  GetOpenFile($input, fptr);
  /*rb_io_check_writable(fptr);*/
  $1 = GetReadFile(fptr);
}

#endif

typedef int Id;
typedef unsigned int Offset;

%nodefault _Repo;
%rename(Repo) _Repo;
typedef struct _Repo {} Repo;

%nodefault _Solvable;
%rename(Solvable) _Solvable;
typedef struct _Solvable {} Solvable;

%nodefault _Relation;
%rename(Relation) _Relation;
typedef struct _Relation {} Relation;

%nodefault _Dependency;
%rename(Dependency) _Dependency;
typedef struct _Dependency {} Dependency;

%nodefault _Action;
%rename(Action) _Action;
typedef struct _Action {} Action;

%nodefault _Transaction;
%rename(Transaction) _Transaction;
typedef struct _Transaction {} Transaction;

%nodefault solver;
%rename(Solver) solver;
typedef struct solver {} Solver;

%nodefault _Decision;
%rename(Decision) _Decision;
typedef struct _Decision {} Decision;

%nodefault _Problem;
%rename(Problem) _Problem;
typedef struct _Problem {} Problem;

/*-------------------------------------------------------------*/
/* Pool */

%newobject pool_create;
%delobject pool_free;

typedef struct _Pool {} Pool;
%rename(Pool) _Pool;

%extend Pool {

  /*
   * Pool management
   */
   
  Pool()
  { return pool_create(); }

  ~Pool()
  { pool_free($self); }

#if defined(SWIGRUBY)
  %rename( "arch=" ) set_arch( const char *arch );
#endif
  void set_arch( const char *arch )
  { pool_setarch( $self, arch ); }

#if defined(SWIGRUBY)
  %rename( "debug=" ) set_debug( int level );
#endif
  void set_debug( int level )
  { pool_setdebuglevel( $self, level ); }

  int promoteepoch()
  { return $self->promoteepoch; }
#if defined(SWIGRUBY)
  %rename( "promoteepoch=" ) set_promoteepoch( int level );
#endif
  void set_promoteepoch( int b )
  { $self->promoteepoch = b; }

  void prepare()
  { pool_createwhatprovides( $self ); }

  /*
   * Name management
   */
  Id str2id( const char *name )
  {
    return str2id( $self, name, 1 );
  }
  const char *id2str( Id id )
  {
    return my_id2str( $self, id );
  }

  /*
   * Repo management
   */

  Repo *add_solv( FILE *fp )
  {
    Repo *repo = repo_create( $self, NULL );
    repo_add_solv( repo, fp );
    return repo;
  }

  Repo *add_solv( const char *fname )
  {
    Repo *repo = repo_create( $self, NULL );
    FILE *fp = fopen( fname, "r");
    if (fp) {
      repo_add_solv( repo, fp );
      fclose( fp );
    }
    return repo;
  }

  Repo *add_rpmdb( const char *rootdir )
  {
    Repo *repo = repo_create( $self, NULL );
    repo_add_rpmdb( repo, NULL, rootdir );
    return repo;
  }

  Repo *create_repo( const char *name )
  { return repo_create( $self, name ); }

  int count_repos()
  { return $self->nrepos; }

  Repo *get_repo( int i )
  {
    if ( i < 0 ) return NULL;
    if ( i >= $self->nrepos ) return NULL;
    return $self->repos[i];
  }

#if defined(SWIGRUBY)
  void each_repo()
  {
    int i;
    for (i = 0; i < $self->nrepos; ++i )
      rb_yield(SWIG_NewPointerObj((void*) $self->repos[i], SWIGTYPE_p__Repo, 0));
  }
#endif

  Repo *find_repo( const char *name )
  {
    int i;
    for (i = 0; i < $self->nrepos; ++i ) {
      if (!strcmp( $self->repos[i]->name, name ))
        return $self->repos[i];
    }
    return NULL;
  }

  /*
   * Solvable management
   */

  int size()
  { return $self->nsolvables; }
  
#if defined(SWIGRUBY)
  %rename( "installable?" ) installable( Solvable *s );
#endif
  int installable( Solvable *s )
  { return pool_installable( $self, s ); }

  /* without the %rename, swig converts it to 'id_2solvable'. Ouch! */
  %rename( "id2solvable" ) id2solvable( Id p );
  Solvable *id2solvable( Id p )
  { return pool_id2solvable( $self, p );  }

#if defined(SWIGRUBY)
  /* %rename is rejected by swig for [] */
  %alias get_solvable "[]";
#endif
  Solvable *get_solvable( int i )
  {
    if (i < 0) return NULL;
    if (i >= $self->nsolvables) return NULL;
    return $self->solvables + i;
  }
#if defined(SWIGRUBY)
  void each()
  {
    Solvable *s;
    Id p;
    for (p = 1, s = $self->solvables + p; p < $self->nsolvables; p++, s++)
    {
      if (!s->name)
        continue;
      rb_yield(SWIG_NewPointerObj((void*) s, SWIGTYPE_p__Solvable, 0));
    }
  }
#endif

  Solvable *
  find( char *name, Repo *repo = NULL )
  {
    Id id;
    Queue plist;
    int i, end;
    Solvable *s;
    Pool *pool;

    pool = $self;
    id = str2id(pool, name, 1);
    queue_init( &plist);
    i = repo ? repo->start : 1;
    end = repo ? repo->start + repo->nsolvables : pool->nsolvables;
    for (; i < end; i++)
    {
      s = pool->solvables + i;
      if (!pool_installable(pool, s))
        continue;
      if (s->name == id)
        queue_push(&plist, i);
    }

    prune_best_version_arch(pool, &plist);

    if (plist.count == 0)
    {
      printf("unknown package '%s'\n", name);
      exit(1);
    }

    id = plist.elements[0];
    queue_free(&plist);

    return pool->solvables + id;
  }

  /*
   * Transaction management
   */
   
  Transaction *create_transaction()
  { return transaction_new( $self ); }

  /*
   * Solver management
   */

  Solver* create_solver( Repo *installed )
  { return solver_create( $self, installed ); }

}

/*-------------------------------------------------------------*/
/* Repo */

%extend Repo {
  Repo( Pool *pool, const char *reponame )
  { return repo_create( pool, reponame ); }

  int size()
  { return $self->nsolvables; }
#if defined(SWIGRUBY)
  %rename("empty?") empty();
#endif
  int empty()
  { return $self->nsolvables == 0; }

  const char *name()
  { return $self->name; }
#if defined(SWIGRUBY)
  %rename( "name=" ) set_name( const char *name );
#endif
  void set_name( const char *name )
  { $self->name = name; }
  int priority()
  { return $self->priority; }
#if defined(SWIGRUBY)
  %rename( "priority=" ) set_priority( int i );
#endif
  void set_priority( int i )
  { $self->priority = i; }
  Pool *pool()
  { return $self->pool; }

  void add_solv( FILE *fp )
  { repo_add_solv( $self, fp ); }

  void add_solv( const char *fname )
  {
    FILE *fp = fopen( fname, "r");
    if (fp) {
      repo_add_solv( $self, fp );
      fclose( fp );
    }
  }

  void add_rpmdb( const char *rootdir )
  { repo_add_rpmdb( $self, NULL, rootdir ); }

  Solvable *create_solvable( const char *name, const char *evr, const char *arch = NULL )
  { return solvable_new( $self, name, evr, arch ); }

#if defined(SWIGRUBY)
  void each()
  {
    Solvable *s;
    Id p;
    for (p = 0, s = $self->pool->solvables + $self->start; p < $self->nsolvables; p++, s++)
    {
      if (!s)
        continue;
      rb_yield( SWIG_NewPointerObj((void*) s, SWIGTYPE_p__Solvable, 0) );
    }
  }
#endif

#if defined(SWIGRUBY)
  /* %rename is rejected by swig for [] */
  %alias get_solvable "[]";
#endif
  Solvable *get_solvable( int i )
  {
    if (i < 0) return NULL;
    if (i >= $self->nsolvables) return NULL;
    return pool_id2solvable( $self->pool, $self->start + i );
  }
}

/*-------------------------------------------------------------*/
/* Relation */

%extend Relation {
/* operation */
#define REL_GT 1
#define REL_EQ 2
#define REL_GE 3
#define REL_LT 4
#define REL_NE 5
#define REL_LE 6
#define REL_AND 16
#define REL_OR 17
#define REL_WITH 18
#define REL_NAMESPACE 18

  %feature("autodoc", "1");
  Relation( Pool *pool, const char *name, int op = 0, const char *evr = NULL )
  {
    Id name_id = str2id( pool, name, 1 );
    Id evr_id = 0;
    if (evr)
      evr_id = str2id( pool, evr, 1 );
    Id rel = rel2id( pool, name_id, evr_id, op, 1 );
    return relation_new( pool, rel );
  }
  ~Relation()
  { free( $self ); }
  %rename("to_s") asString();
  const char *asString()
  {
    return dep2str( $self->pool, $self->id );
  }
  const char *name()
  {
    Reldep *rd = GETRELDEP( $self->pool, $self->id );
    return my_id2str( $self->pool, rd->name );
  }
  const char *evr()
  {
    Reldep *rd = GETRELDEP( $self->pool, $self->id );
    return my_id2str( $self->pool, rd->evr );
  }
  int op()
  {
    Reldep *rd = GETRELDEP( $self->pool, $self->id );
    return rd->flags;
  }
#if defined(SWIGRUBY)
  %alias cmp "<=>";
#endif
  int cmp( const Relation *r )
  { return evrcmp( $self->pool, $self->id, r->id, EVRCMP_COMPARE ); }
#if defined(SWIGRUBY)
  %alias match "=~";
#endif
  int match( const Relation *r )
  { return evrcmp( $self->pool, $self->id, r->id, EVRCMP_MATCH_RELEASE ) == 0; }
}

/*-------------------------------------------------------------*/
/* Dependency */

%extend Dependency {
#define DEP_PRV 1
#define DEP_REQ 2
#define DEP_CON 3
#define DEP_OBS 4
#define DEP_REC 5
#define DEP_SUG 6
#define DEP_SUP 7
#define DEP_ENH 8

  Dependency( Solvable *solvable, int dep )
  { return dependency_new( solvable, NULL, dep ); }
  ~Dependency()
  { free( $self ); }

  int size()
  { return dependency_size( $self ); }
#if defined(SWIGRUBY)
  %rename("empty?") empty();
#endif
  int empty()
  { return dependency_size( $self ) == 0; }

#if defined(SWIGRUBY)
  %alias add_relation "<<";
#endif
  Dependency *add_relation( Relation *rel, int pre = 0 )
  {
    *($self->relations) = repo_addid_dep( $self->solvable->repo, *($self->relations), rel->id, pre ? SOLVABLE_PREREQMARKER : 0 );
    return $self;
  }
  
#if defined(SWIGRUBY)
  /* %rename is rejected by swig for [] */
  %alias get_relation "[]";
#endif
  Relation *get_relation( int i )
  {
    /* loop over it to detect end */
    Id *ids = $self->solvable->repo->idarraydata + *($self->relations);
    while ( i-- >= 0 ) {
      if ( !*ids )
	 break;
      if ( i == 0 ) {
	return relation_new( $self->solvable->repo->pool, *ids );
      }
      ++ids;
    }
    return NULL;
  }

#if defined(SWIGRUBY)
  void each()
  {
    Id *ids = $self->solvable->repo->idarraydata + *($self->relations);
    while (*ids) {
      rb_yield( SWIG_NewPointerObj((void*) relation_new( $self->solvable->repo->pool, *ids ), SWIGTYPE_p__Relation, 0) );
      ++ids;
    }
  }
#endif

}

/*-------------------------------------------------------------*/
/* Solvable */

%extend Solvable {
  Solvable( Repo *repo, const char *name, const char *evr, const char *arch = NULL )
  { return solvable_new( repo, name, evr, arch ); }

  Id id() {
    if (!$self->repo)
      return 0;
    return $self - $self->repo->pool->solvables;
  }

  const char *name()
  { return my_id2str( $self->repo->pool, $self->name ); }
  Id name_id()
  { return $self->name; }
  const char *arch()
  { return my_id2str( $self->repo->pool, $self->arch ); }
  Id arch_id()
  { return $self->arch; }
  const char *evr()
  { return my_id2str( $self->repo->pool, $self->evr ); }
  Id evr_id()
  { return $self->evr; }

  const char *vendor()
  { return my_id2str( $self->repo->pool, $self->vendor ); }
#if defined(SWIGRUBY)
  %rename( "vendor=" ) set_vendor( const char *vendor );
#endif
  void set_vendor(const char *vendor)
  { $self->vendor = str2id( $self->repo->pool, vendor, 1 ); }
  Id vendor_id()
  { return $self->vendor; }

  %rename("to_s") asString();
  const char * asString()
  {
    if ( !$self->repo )
        return "<UNKNOWN>";
    return solvable2str( $self->repo->pool, $self );
  }

  /*
   * Dependencies
   */
  Dependency *provides()
  { return dependency_new( $self, &(self->provides), 0 ); }
  Dependency *requires()
  { return dependency_new( $self, &(self->requires), 0 ); }
  Dependency *conflicts()
  { return dependency_new( $self, &(self->conflicts), 0 ); }
  Dependency *obsoletes()
  { return dependency_new( $self, &(self->obsoletes), 0 ); }
  Dependency *recommends()
  { return dependency_new( $self, &(self->recommends), 0 ); }
  Dependency *suggests()
  { return dependency_new( $self, &(self->suggests), 0 ); }
  Dependency *supplements()
  { return dependency_new( $self, &(self->supplements), 0 ); }
  Dependency *enhances()
  { return dependency_new( $self, &(self->enhances), 0 ); }
}

/*-------------------------------------------------------------*/
/* Action */

%extend Action {
  %constant int INSTALL_SOLVABLE = 1;
  %constant int REMOVE_SOLVABLE = 2;
  %constant int INSTALL_SOLVABLE_NAME = 3;
  %constant int REMOVE_SOLVABLE_NAME = 4;
  %constant int INSTALL_SOLVABLE_PROVIDES = 5;
  %constant int REMOVE_SOLVABLE_PROVIDES = 6;
  
  Action( int cmd, Id id )
  { return action_new( cmd, id ); }
  ~Action()
  { free( $self ); }
  int cmd()
  { return $self->cmd; }
  Id id()
  { return $self->id; }
}

/*-------------------------------------------------------------*/
/* Transaction */

%extend Transaction {
  Transaction( Pool *pool )
  { return transaction_new( pool ); }

  ~Transaction()
  { transaction_free( $self ); }

  Action *shift()
  {
    int cmd = queue_shift( &($self->queue) );
    Id id = queue_shift( &($self->queue) );
    return action_new( cmd, id );
  }
  
  void push( const Action *action )
  {
    queue_push( &($self->queue), action->cmd );
    queue_push( &($self->queue), action->id );
  }

  void install( Solvable *s )
  {
    queue_push( &($self->queue), SOLVER_INSTALL_SOLVABLE );
    /* FIXME: check: s->repo->pool == $self->pool */
    queue_push( &($self->queue), (s - s->repo->pool->solvables) );
  }
  void remove( Solvable *s )
  {
    queue_push( &($self->queue), SOLVER_ERASE_SOLVABLE );
    /* FIXME: check: s->repo->pool == $self->pool */
    queue_push( &($self->queue), (s - s->repo->pool->solvables) );
  }
  void install( const char *name )
  {
    queue_push( &($self->queue), SOLVER_INSTALL_SOLVABLE_NAME );
    queue_push( &($self->queue), str2id( $self->pool, name, 1 ));
  }
  void remove( const char *name )
  {
    queue_push( &($self->queue), SOLVER_ERASE_SOLVABLE_NAME );
    queue_push( &($self->queue), str2id( $self->pool, name, 1 ));
  }
  void install( const Relation *rel )
  {
    queue_push( &($self->queue), SOLVER_INSTALL_SOLVABLE_PROVIDES );
    /* FIXME: check: rel->pool == $self->pool */
    Reldep *rd = GETRELDEP( rel->pool, rel->id );
    queue_push( &($self->queue), rd->name );
  }
  void remove( const Relation *rel )
  {
    queue_push( &($self->queue), SOLVER_ERASE_SOLVABLE_PROVIDES );
    /* FIXME: check: rel->pool == $self->pool */
    Reldep *rd = GETRELDEP( rel->pool, rel->id );
    queue_push( &($self->queue), rd->name );
  }

#if defined(SWIGRUBY)
  %rename("empty?") empty();
#endif
  int empty()
  { return ( $self->queue.count == 0 ); }

  int size()
  { return $self->queue.count >> 1; }

#if defined(SWIGRUBY)
  %rename("clear!") clear();
#endif
  void clear()
  { queue_empty( &($self->queue) ); }

  Action *get_action( unsigned int i )
  {
    i <<= 1;
    int size = $self->queue.count;
    if (i-1 >= size) return NULL;
    int cmd = $self->queue.elements[i];
    Id id = $self->queue.elements[i+1];
    return action_new( cmd, id );
  }

#if defined(SWIGRUBY)
  void each()
  {
    int i;
    for (i = 0; i < $self->queue.count-1; ) {
      int cmd = $self->queue.elements[i++];
      Id id = $self->queue.elements[i++];
      rb_yield(SWIG_NewPointerObj((void*) action_new( cmd, id ), SWIGTYPE_p__Action, 0));
    }
  }
#endif
}

/*-------------------------------------------------------------*/
/* Decision */

%extend Decision {
  %constant int DEC_INSTALL = 1;
  %constant int DEC_REMOVE = 2;
  %constant int DEC_UPDATE = 3;
  %constant int DEC_OBSOLETE = 4;
  
  Decision( int op, Solvable *solvable, Solvable *reason = NULL )
  { return decision_new( op, solvable, reason ); }
  ~Decision()
  { free( $self ); }
  int op()
  { return $self->op; }
  Solvable *solvable()
  { return $self->solvable; }
  Solvable *reason()
  { return $self->reason; }
}

/*-------------------------------------------------------------*/
/* Problem */

%extend Problem {
  %constant int SOLVER_PROBLEM_UPDATE_RULE = 1;
  %constant int SOLVER_PROBLEM_JOB_RULE = 2;
  %constant int SOLVER_PROBLEM_JOB_NOTHING_PROVIDES_DEP = 3;
  %constant int SOLVER_PROBLEM_NOT_INSTALLABLE = 4;
  %constant int SOLVER_PROBLEM_NOTHING_PROVIDES_DEP = 5;
  %constant int SOLVER_PROBLEM_SAME_NAME = 6;
  %constant int SOLVER_PROBLEM_PACKAGE_CONFLICT = 7;
  %constant int SOLVER_PROBLEM_PACKAGE_OBSOLETES = 8;
  %constant int SOLVER_PROBLEM_DEP_PROVIDERS_NOT_INSTALLABLE = 8;
  int reason()
  { return $self->reason; }
  Solvable *source()
  { return $self->source; }
  Relation *relation()
  { return $self->relation; }
  Solvable *target()
  { return $self->target; }
}

/*-------------------------------------------------------------*/
/* Solver */

%extend Solver {

  Solver( Pool *pool, Repo *installed )
  { return solver_create( pool, installed ); }
  ~Solver()
  { solver_free( $self ); }

  /* yeah, thats awkward. But %including solver.h and adding lots
     of %ignores is even worse ... */

  int fix_system()
  { return $self->fixsystem; }
#if defined(SWIGRUBY)
  %rename( "fix_system=" ) set_fix_system( int i );
#endif
  void set_fix_system( int i )
  { $self->fixsystem = i; }

  int update_system()
  { return $self->updatesystem; }
#if defined(SWIGRUBY)
  %rename( "update_system=" ) set_update_system( int i );
#endif
  void set_update_system( int i )
  { $self->updatesystem = i; }

  int allow_downgrade()
  { return $self->allowdowngrade; }
#if defined(SWIGRUBY)
  %rename( "allow_downgrade=" ) set_allow_downgrade( int i );
#endif
  void set_allow_downgrade( int i )
  { $self->allowdowngrade = i; }

  int allow_uninstall()
  { return $self->allowuninstall; }
#if defined(SWIGRUBY)
  %rename( "allow_uninstall=" ) set_allow_uninstall( int i );
#endif
  void set_allow_uninstall( int i )
  { $self->allowuninstall = i; }

  int no_update_provide()
  { return $self->noupdateprovide; }
#if defined(SWIGRUBY)
  %rename( "no_update_provide=" ) set_no_update_provide( int i );
#endif
  void set_no_update_provide( int i )
  { $self->noupdateprovide = i; }

  void solve( Transaction *t )
  { solver_solve( $self, &(t->queue)); }
  int decision_count()
  { return $self->decisionq.count; }
#if defined(SWIGRUBY)
  void each_decision()
  {
    Pool *pool = $self->pool;
    Repo *installed = $self->installed;
    Id p, *obsoletesmap = create_obsoletesmap( $self );
    Solvable *s, *r;
    int op;
    Decision *d;
#if 0   
    if (installed) {
      FOR_REPO_SOLVABLES(installed, p, s) {
	if ($self->decisionmap[p] >= 0)
	  continue;
	if (obsoletesmap[p]) {
	  d = decision_new( DEC_OBSOLETE, s, pool_id2solvable( pool, obsoletesmap[p] ) );
        }
	else {
          d = decision_new( DEC_REMOVE, s, NULL );
	}
        rb_yield(SWIG_NewPointerObj((void*) d, SWIGTYPE_p__Decision, 0));
      }
    }
#endif
    int i;
    for ( i = 0; i < $self->decisionq.count; i++)
    {
      p = $self->decisionq.elements[i];
      r = NULL;

      if (p < 0) {     /* remove */
        p = -p;
        s = pool_id2solvable( pool, p );
	if (obsoletesmap[p]) {
	  op = DEC_OBSOLETE;
	  r = pool_id2solvable( pool, obsoletesmap[p] );
        }
	else {
	  op = DEC_REMOVE;
	}
      }
      else if (p == SYSTEMSOLVABLE) {
        continue;
      }
      else {
        s = pool->solvables + p;
        if (installed && s->repo == installed)
	  continue;

        if (!obsoletesmap[p]) {
          op = DEC_INSTALL;
        }
        else {
          op = DEC_UPDATE;
	  int j;
	  for (j = installed->start; j < installed->end; j++) {
	    if (obsoletesmap[j] == p) {
	      r = pool_id2solvable( pool, j );
	      break;
	    }
	  }
        }
      }
      d = decision_new( op, s, r );
      rb_yield(SWIG_NewPointerObj((void*) d, SWIGTYPE_p__Decision, 0));
    }
  }
#endif
  int problem_count()
  { return $self->problems.count; }
#if defined(SWIGRUBY)
  %rename("problems?") problems_found();
#endif
  int problems_found()
  { return $self->problems.count != 0; }
#if defined(SWIGRUBY)
  void each_problem( Transaction *t )
  {
    Pool *pool = $self->pool;
    Queue *transaction = &(t->queue);

    Id problem = 0;
    while ((problem = solver_next_problem( $self, problem )) != 0) {
      Id prule;
      Id dep, source, target;
      Problem *p;
      int reason;

      prule = solver_findproblemrule( $self, problem );
      reason = solver_problemruleinfo( $self, transaction, prule, &dep, &source, &target ); 
      p = problem_new( reason, pool_id2solvable( pool, source ), relation_new( pool, dep ), pool_id2solvable( pool, target ) );
      rb_yield( SWIG_NewPointerObj((void*) p, SWIGTYPE_p__Problem, 0) );
    }
  }
#endif

#if defined(SWIGRUBY)
  void each_to_install()
  {
    Id p;
    Solvable *s;
    int i;
    for ( i = 0; i < $self->decisionq.count; i++)
    {
      p = $self->decisionq.elements[i];
      if (p <= 0)
        continue;       /* conflicting package, ignore */
      if (p == SYSTEMSOLVABLE)
        continue;       /* system resolvable, always installed */

      // getting repo
      s = $self->pool->solvables + p;
      Repo *repo = s->repo;
      if (!repo || repo == $self->installed)
        continue;       /* already installed resolvable */
      rb_yield(SWIG_NewPointerObj((void*) s, SWIGTYPE_p__Solvable, 0));
    }
  }

  void each_to_remove()
  {
    Id p;
    Solvable *s;

    if (!$self->installed)
      return;
    /* solvables to be removed */
    FOR_REPO_SOLVABLES($self->installed, p, s)
    {
      if ($self->decisionmap[p] >= 0)
        continue;       /* we keep this package */
      rb_yield(SWIG_NewPointerObj((void*) s, SWIGTYPE_p__Solvable, 0));
    }
  }

  void each_suggested()
  {
    int i;
    Solvable *s;
    for (i = 0; i < $self->suggestions.count; i++) {
      s = $self->pool->solvables + $self->suggestions.elements[i];
      rb_yield(SWIG_NewPointerObj((void*) s, SWIGTYPE_p__Solvable, 0));
    }
  }

#endif

};
