I'll write the whole set of files and test them on your example before giving them to you.

I wrote and tested this whole set on your example (flex 2.6, bison 3.8, gcc). Everything builds and the output is shown below. It uses only lex and yacc plus the C code inside them, and I wrote fresh files rather than reusing your uploaded ones, so the names below are the ones to use. `-lfl` is not needed because each lexer has `%option noyywrap`.

## 0. Setup

```bash
sudo apt install flex bison gcc      # Ubuntu / WSL
mkdir minicc && cd minicc
```

**input.c**
```c
while (m < n * 4)
{
    r = 16 * 5;
    s = x * y + z;
    t = m + s;
}
```

## The pipeline (memorize this)

```
input.c → [1 lexer] tokens
        → [2 syntax] parse OK / reductions
        → [3 icg]  TAC            → tac.txt
        → [4 optimizer] better TAC → opt.txt
        → [5 target] assembly
        [6 run.sh] runs 1 to 5 in one go
```
Memory trick: **L-S-T-O-A** (Lexer, Syntax, Three-address, Optimizer, Assembly). Each stage reads the previous stage's output file.

---

## STEP 1: Lexical analysis (`lexer.l`)

It splits the text into tokens and labels each one.

```lex
%{
#include <stdio.h>
int cnt = 0;
void show(const char *type) { printf("%-4d %-12s %s\n", ++cnt, type, yytext); }
%}
%option noyywrap
%%
"while"|"for"|"if"|"else"     { show("KEYWORD"); }
[0-9]+                        { show("NUMBER"); }
[A-Za-z_][A-Za-z0-9_]*        { show("IDENTIFIER"); }
"<="|">="|"=="|"!="|"<"|">"   { show("RELOP"); }
"="                           { show("ASSIGN"); }
[-+*/]                        { show("ARITH_OP"); }
[(){};]                       { show("SEPARATOR"); }
[ \t\r\n]+                    ;
.                             { printf("LEXICAL ERROR: unknown character '%s'\n", yytext); }
%%
int main() {
    printf("No   Token        Lexeme\n----------------------------\n");
    yylex();
    printf("----------------------------\nTotal tokens = %d\n", cnt);
    return 0;
}
```
```bash
flex -o lexer1.yy.c lexer.l
gcc lexer1.yy.c -o lexer
./lexer < input.c
```
Output starts with `1 KEYWORD while`, `2 SEPARATOR (`, `3 IDENTIFIER m`, `4 RELOP <`, `5 IDENTIFIER n`, `6 ARITH_OP *`, and so on.

**Key point:** keywords come before the identifier rule, because flex picks the longest match and, on a tie, the earlier rule.

---

## STEP 2: Syntax analysis (`syntax.l` + `syntax.y`)

It checks the grammar and prints each reduction (bottom-up parsing).

**syntax.l**
```lex
%{
#include <string.h>
#include "syntax.tab.h"
%}
%option noyywrap yylineno
%%
"while"                       { return WHILE; }
"for"                         { return FOR; }
"if"                          { return IF; }
"else"                        { return ELSE; }
[0-9]+                        { strcpy(yylval.str, yytext); return NUMBER; }
[A-Za-z_][A-Za-z0-9_]*        { strcpy(yylval.str, yytext); return ID; }
"<="|">="|"=="|"!="|"<"|">"   { strcpy(yylval.str, yytext); return RELOP; }
[-+*/=(){};]                  { return yytext[0]; }
[ \t\r\n]+                    ;
.                             { fprintf(stderr, "Lexical error: '%s' at line %d\n", yytext, yylineno); }
%%
```

**syntax.y**
```yacc
%{
#include <stdio.h>
extern int yylineno;
int yylex(void);
void yyerror(const char *s);
#define R(x) printf("  reduce: %s\n", x)
%}
%union { char str[100]; }
%token <str> ID NUMBER RELOP
%token WHILE FOR IF ELSE
%nonassoc LOWER_THAN_ELSE
%nonassoc ELSE
%%
program   : stmt_list                 { R("program -> stmt_list"); printf("\n>>> SYNTAX IS VALID <<<\n"); } ;
stmt_list : stmt_list stmt            { R("stmt_list -> stmt_list stmt"); }
          | stmt                      { R("stmt_list -> stmt"); } ;
stmt      : assign ';'                { R("stmt -> assign ;"); }
          | WHILE '(' cond ')' stmt   { R("stmt -> while ( cond ) stmt"); }
          | FOR '(' assign ';' cond ';' assign ')' stmt { R("stmt -> for ( assign ; cond ; assign ) stmt"); }
          | IF '(' cond ')' stmt %prec LOWER_THAN_ELSE  { R("stmt -> if ( cond ) stmt"); }
          | IF '(' cond ')' stmt ELSE stmt              { R("stmt -> if ( cond ) stmt else stmt"); }
          | '{' stmt_list '}'         { R("stmt -> { stmt_list }"); } ;
assign    : ID '=' expr               { R("assign -> ID = expr"); } ;
cond      : expr RELOP expr           { R("cond -> expr RELOP expr"); }
          | expr                      { R("cond -> expr"); } ;
expr      : expr '+' term             { R("expr -> expr + term"); }
          | expr '-' term             { R("expr -> expr - term"); }
          | term                      { R("expr -> term"); } ;
term      : term '*' factor           { R("term -> term * factor"); }
          | term '/' factor           { R("term -> term / factor"); }
          | factor                    { R("term -> factor"); } ;
factor    : '(' expr ')'              { R("factor -> ( expr )"); }
          | ID                        { R("factor -> ID"); }
          | NUMBER                    { R("factor -> NUMBER"); } ;
%%
void yyerror(const char *s) { fprintf(stderr, "SYNTAX ERROR near line %d: %s\n", yylineno, s); }
int main() { return yyparse(); }
```
```bash
bison -d -o syntax.tab.c syntax.y
flex  -o syntax.lex.c syntax.l
gcc syntax.tab.c syntax.lex.c -o syntax
./syntax < input.c
```
It ends with `>>> SYNTAX IS VALID <<<`.

**Operator precedence:** it comes from the grammar layers. `expr` handles `+ -`, and `term` handles `* /`. Because `*` sits lower in the grammar, it binds tighter. Say this to ma'am.

**Dangling else:** `%nonassoc LOWER_THAN_ELSE` and `%nonassoc ELSE` make an `else` pair with the nearest `if`.

---

## STEP 3: Intermediate code generation (`tac.l` + `tac.y`)

It produces three-address code (TAC) with temporaries `t1, t2…` and labels `L1, L2…`.

```bash
sed 's/syntax.tab.h/tac.tab.h/' syntax.l > tac.l     # same lexer, only the include changes
```

**tac.y**
```yacc
%{
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
extern int yylineno;
int yylex(void);
void yyerror(const char *s);
int tcount = 0, lcount = 0;
char held[50][2000]; int nheld = 0; char *cap = NULL;   /* buffer to delay 'for' increment code */
void emit(const char *f, ...) {
    char b[300]; va_list ap; va_start(ap, f); vsnprintf(b, sizeof b, f, ap); va_end(ap);
    if (cap) strcat(cap, b); else fputs(b, stdout);
}
void newtemp(char *s) { sprintf(s, "t%d", ++tcount); }
int  newlabel() { return ++lcount; }
%}
%union { char str[100]; int n; }
%token <str> ID NUMBER RELOP
%token WHILE FOR IF ELSE
%nonassoc LOWER_THAN_ELSE
%nonassoc ELSE
%type <str> expr term factor cond
%type <n> ifhead
%%
program   : stmt_list ;
stmt_list : stmt_list stmt | stmt ;

stmt : assign ';'
     | WHILE { $<n>$ = newlabel(); emit("L%d:\n", $<n>$); }
       '(' cond ')' { $<n>$ = newlabel(); emit("ifFalse %s goto L%d\n", $4, $<n>$); }
       stmt { emit("goto L%d\nL%d:\n", $<n>2, $<n>6); }

     | FOR '(' assign ';' { $<n>$ = newlabel(); emit("L%d:\n", $<n>$); }
       cond ';' { $<n>$ = newlabel(); emit("ifFalse %s goto L%d\n", $6, $<n>$); }
       { $<n>$ = nheld++; held[$<n>$][0] = 0; cap = held[$<n>$]; }
       assign ')' { cap = NULL; }
       stmt { emit("%s", held[$<n>9]); emit("goto L%d\nL%d:\n", $<n>5, $<n>8); }

     | ifhead stmt %prec LOWER_THAN_ELSE { emit("L%d:\n", $1); }
     | ifhead stmt ELSE { $<n>$ = newlabel(); emit("goto L%d\nL%d:\n", $<n>$, $1); }
       stmt { emit("L%d:\n", $<n>4); }
     | '{' stmt_list '}'
     ;
ifhead : IF '(' cond ')' { $$ = newlabel(); emit("ifFalse %s goto L%d\n", $3, $$); } ;

assign : ID '=' expr { emit("%s = %s\n", $1, $3); } ;
cond   : expr RELOP expr { newtemp($$); emit("%s = %s %s %s\n", $$, $1, $2, $3); }
       | expr            { strcpy($$, $1); } ;
expr   : expr '+' term { newtemp($$); emit("%s = %s + %s\n", $$, $1, $3); }
       | expr '-' term { newtemp($$); emit("%s = %s - %s\n", $$, $1, $3); }
       | term          { strcpy($$, $1); } ;
term   : term '*' factor { newtemp($$); emit("%s = %s * %s\n", $$, $1, $3); }
       | term '/' factor { newtemp($$); emit("%s = %s / %s\n", $$, $1, $3); }
       | factor          { strcpy($$, $1); } ;
factor : '(' expr ')' { strcpy($$, $2); }
       | ID           { strcpy($$, $1); }
       | NUMBER       { strcpy($$, $1); } ;
%%
void yyerror(const char *s) { fprintf(stderr, "SYNTAX ERROR near line %d: %s\n", yylineno, s); }
int main() { return yyparse(); }
```
```bash
bison -d -o tac.tab.c tac.y
flex  -o tac.lex.c tac.l
gcc tac.tab.c tac.lex.c -o icg
./icg < input.c | tee tac.txt
```
Output:
```
L1:
t1 = n * 4
t2 = m < t1
ifFalse t2 goto L2
t3 = 16 * 5
r = t3
t4 = x * y
t5 = t4 + z
s = t5
t6 = m + s
t = t6
goto L1
L2:
```
**How it works:**
- Every expression rule makes a new temp and prints one TAC line.
- `while` prints a label first, the `ifFalse` jump after the condition, then `goto` and the exit label at the end.
- The `for` loop's increment is parsed before the body but must be printed after it, so it is held in a buffer.

---

## STEP 4: Code optimization (`optimizer.l` + `optimizer.y`)

This stage reads the TAC text with lex and yacc, stores each line in an array, and runs four passes in C inside the `.y` file. The log goes to the screen (stderr) and the clean optimized TAC goes to stdout.

**optimizer.l** (this is also the lexer for Step 5)
```lex
%{
#include <string.h>
#include "optimizer.tab.h"
%}
%option noyywrap
%%
"ifFalse"                                         { return IFFALSE; }
"goto"                                            { return GOTO; }
-?[0-9]+                                          { strcpy(yylval.str, yytext); return NUM; }
[A-Za-z_][A-Za-z0-9_]*                            { strcpy(yylval.str, yytext); return ID; }
"<<"|"<="|">="|"=="|"!="|"<"|">"|"+"|"-"|"*"|"/" { strcpy(yylval.str, yytext); return OP; }
"="                                               { return '='; }
":"                                               { return ':'; }
\n                                                { return NL; }
[ \t\r]+                                          ;
"//".*                                            ;
.                                                 { fprintf(stderr, "bad character '%s'\n", yytext); }
%%
```

**optimizer.y**
```yacc
%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>
int yylex(void);
void yyerror(const char *s);

enum { K_LABEL, K_COPY, K_BIN, K_IFF, K_GOTO };
typedef struct { int k; char res[32], a[32], op[4], b[32]; } Ins;
Ins P[1000]; int n = 0;

void add(int k, const char *r, const char *a, const char *op, const char *b) {
    Ins *p = &P[n++]; p->k = k;
    snprintf(p->res, 32, "%s", r); snprintf(p->a, 32, "%s", a);
    snprintf(p->op, 4, "%s", op);  snprintf(p->b, 32, "%s", b);
}
void note(const char *f, ...) {
    va_list ap; va_start(ap, f); fprintf(stderr, "   * "); vfprintf(stderr, f, ap); fprintf(stderr, "\n"); va_end(ap);
}
void text(Ins *p, char *b) {
    switch (p->k) {
      case K_LABEL: sprintf(b, "%s:", p->res); break;
      case K_COPY:  sprintf(b, "%s = %s", p->res, p->a); break;
      case K_BIN:   sprintf(b, "%s = %s %s %s", p->res, p->a, p->op, p->b); break;
      case K_IFF:   sprintf(b, "ifFalse %s goto %s", p->a, p->res); break;
      default:      sprintf(b, "goto %s", p->res);
    }
}
void dump(FILE *fp) {
    char b[200]; int i;
    for (i = 0; i < n; i++) { text(&P[i], b); fprintf(fp, P[i].k == K_LABEL ? "%s\n" : "    %s\n", b); }
}
int isnum(const char *s) { return isdigit((unsigned char)s[0]) || (s[0]=='-' && isdigit((unsigned char)s[1])); }
int istemp(const char *s) {
    int i; if (s[0] != 't' || !s[1]) return 0;
    for (i = 1; s[i]; i++) if (!isdigit((unsigned char)s[i])) return 0;
    return 1;
}
int pow2(int v) { int k = 0; if (v < 2) return -1; while (v % 2 == 0) { v /= 2; k++; } return v == 1 ? k : -1; }
int isarith(const char *o) { return !strcmp(o,"+")||!strcmp(o,"-")||!strcmp(o,"*")||!strcmp(o,"/")||!strcmp(o,"<<"); }
void tocopy(Ins *p, const char *src) {
    char t[32]; snprintf(t, 32, "%s", src);
    p->k = K_COPY; snprintf(p->a, 32, "%s", t); p->op[0] = 0; p->b[0] = 0;
}
void del(int i) { memmove(&P[i], &P[i+1], (n - i - 1) * sizeof(Ins)); n--; }

int usesin(const char *v, int lo, int hi) {
    int i, c = 0;
    for (i = lo; i <= hi; i++) {
        Ins *p = &P[i];
        if ((p->k==K_COPY || p->k==K_BIN || p->k==K_IFF) && !strcmp(p->a, v)) c++;
        if (p->k==K_BIN && !strcmp(p->b, v)) c++;
    }
    return c;
}
int defs(const char *v, int lo, int hi) {
    int i, c = 0;
    for (i = lo; i <= hi; i++) if ((P[i].k==K_COPY || P[i].k==K_BIN) && !strcmp(P[i].res, v)) c++;
    return c;
}

/* PASS 1: constant folding + algebraic simplification */
void simplify(void) {
    char before[200], after[200]; int i;
    for (i = 0; i < n; i++) {
        Ins *p = &P[i]; char c, s[32]; int done = 0;
        if (p->k != K_BIN) continue;
        c = p->op[0];
        if (p->op[1] || !strchr("+-*/", c)) continue;
        text(p, before);
        if (isnum(p->a) && isnum(p->b)) {
            int x = atoi(p->a), y = atoi(p->b), r;
            if (c == '/' && y == 0) continue;
            r = c=='+' ? x+y : c=='-' ? x-y : c=='*' ? x*y : x/y;
            sprintf(s, "%d", r); tocopy(p, s); text(p, after);
            note("Constant folding      : %s   ->   %s", before, after);
            continue;
        }
        if      (c=='+' && !strcmp(p->b,"0")) { tocopy(p, p->a); done = 1; }
        else if (c=='+' && !strcmp(p->a,"0")) { tocopy(p, p->b); done = 1; }
        else if (c=='-' && !strcmp(p->b,"0")) { tocopy(p, p->a); done = 1; }
        else if (c=='*' && !strcmp(p->b,"1")) { tocopy(p, p->a); done = 1; }
        else if (c=='*' && !strcmp(p->a,"1")) { tocopy(p, p->b); done = 1; }
        else if (c=='*' && (!strcmp(p->a,"0") || !strcmp(p->b,"0"))) { tocopy(p, "0"); done = 1; }
        else if (c=='/' && !strcmp(p->b,"1")) { tocopy(p, p->a); done = 1; }
        if (done) { text(p, after); note("Algebraic simplif.   : %s   ->   %s", before, after); }
    }
}
/* PASS 2: strength reduction  x * 2^k  ->  x << k */
void strength(void) {
    char before[200], after[200]; int i, k;
    for (i = 0; i < n; i++) {
        Ins *p = &P[i];
        if (p->k != K_BIN || strcmp(p->op, "*")) continue;
        text(p, before);
        if (isnum(p->b) && (k = pow2(atoi(p->b))) > 0) { }
        else if (isnum(p->a) && (k = pow2(atoi(p->a))) > 0) { char v[32]; strcpy(v, p->b); strcpy(p->a, v); }
        else continue;
        strcpy(p->op, "<<"); sprintf(p->b, "%d", k); text(p, after);
        note("Strength reduction    : %s   ->   %s", before, after);
    }
}
/* PASS 3: remove useless temporaries  (t = e ; v = t)  ->  (v = e) */
void merge(void) {
    char b1[200], b2[200], after[200]; int i;
    for (i = 0; i + 1 < n; i++) {
        if ((P[i].k==K_BIN || P[i].k==K_COPY) && istemp(P[i].res) &&
            P[i+1].k==K_COPY && !strcmp(P[i+1].a, P[i].res) && usesin(P[i].res, 0, n-1) == 1) {
            text(&P[i], b1); text(&P[i+1], b2);
            snprintf(P[i].res, 32, "%s", P[i+1].res); del(i+1); text(&P[i], after);
            note("Temp elimination      : %s ; %s   ->   %s", b1, b2, after);
        }
    }
}
/* PASS 4: code motion - hoist loop-invariant code out of loops */
int invariant(const char *s, int lo, int hi) { return isnum(s) || defs(s, lo, hi) == 0; }
void motion(void) {
    int changed;
    do {
        int e, s, k; changed = 0;
        for (e = 0; e < n && !changed; e++) {
            if (P[e].k != K_GOTO) continue;
            for (s = 0; s < e; s++) if (P[s].k==K_LABEL && !strcmp(P[s].res, P[e].res)) break;
            if (s >= e) continue;                       /* not a back edge -> not a loop */
            for (k = s + 1; k < e; k++) {
                Ins *p = &P[k]; int ok = 0; char b[200]; Ins t;
                if (p->k == K_BIN)       ok = isarith(p->op) && invariant(p->a, s+1, e-1) && invariant(p->b, s+1, e-1);
                else if (p->k == K_COPY) ok = invariant(p->a, s+1, e-1);
                if (!ok) continue;
                if (!(istemp(p->res) || (p->k == K_COPY && isnum(p->a)))) continue;
                if (defs(p->res, s+1, e-1) != 1) continue;
                if (k > s+1 && usesin(p->res, s+1, k-1)) continue;
                text(p, b); t = *p;
                memmove(&P[s+1], &P[s], (k - s) * sizeof(Ins)); P[s] = t;
                note("Code motion           : '%s' moved out of loop %s", b, P[s+1].res);
                changed = 1; break;
            }
        }
    } while (changed);
}
%}
%union { char str[100]; }
%token <str> ID NUM OP
%token IFFALSE GOTO NL
%type <str> operand
%%
prog : /* empty */ | prog line ;
line : ID ':' NL                    { add(K_LABEL, $1, "", "", ""); }
     | ID '=' operand NL            { add(K_COPY,  $1, $3, "", ""); }
     | ID '=' operand OP operand NL { add(K_BIN,   $1, $3, $4, $5); }
     | IFFALSE operand GOTO ID NL   { add(K_IFF,   $4, $2, "", ""); }
     | GOTO ID NL                   { add(K_GOTO,  $2, "", "", ""); }
     | NL ;
operand : ID { strcpy($$, $1); } | NUM { strcpy($$, $1); } ;
%%
void yyerror(const char *s) { fprintf(stderr, "TAC syntax error: %s\n", s); }
int main() {
    if (yyparse()) return 1;
    fprintf(stderr, "--- Unoptimized TAC ---\n"); dump(stderr);
    fprintf(stderr, "\n--- Optimization steps ---\n");
    simplify(); strength(); merge(); motion();
    fprintf(stderr, "\n--- Optimized TAC ---\n");
    dump(stdout);
    return 0;
}
```
```bash
bison -d -o optimizer.tab.c optimizer.y
flex  -o optimizer.lex.c optimizer.l
gcc optimizer.tab.c optimizer.lex.c -o optimizer
./optimizer < tac.txt | tee opt.txt
```
Actual output:
```
--- Optimization steps ---
   * Constant folding      : t3 = 16 * 5   ->   t3 = 80
   * Strength reduction    : t1 = n * 4   ->   t1 = n << 2
   * Temp elimination      : t3 = 80 ; r = t3   ->   r = 80
   * Temp elimination      : t5 = t4 + z ; s = t5   ->   s = t4 + z
   * Temp elimination      : t6 = m + s ; t = t6   ->   t = m + s
   * Code motion           : 't1 = n << 2' moved out of loop L1
   * Code motion           : 'r = 80' moved out of loop L1
   * Code motion           : 't4 = x * y' moved out of loop L1

--- Optimized TAC ---
    t1 = n << 2
    r = 80
    t4 = x * y
L1:
    t2 = m < t1
    ifFalse t2 goto L2
    s = t4 + z
    t = m + s
    goto L1
L2:
```

| Technique | Where it shows up |
|---|---|
| Constant folding | `16 * 5` becomes `80` |
| Strength reduction | `n * 4` becomes `n << 2` |
| Code motion | `n<<2`, `r = 80` and `x*y` are computed once, before `L1` |
| Algebraic simplification | `x+0`, `x*1`, `x*0`, `x/1`. It doesn't fire on this example; test with `a = b + 0;` inside the loop. |

**Limitation to mention:** code motion hoists an instruction only if its operands are not changed inside the loop. It does not check whether the instruction sits inside an `if` within the loop.

---

## STEP 5: Target code generation (`target.l` + `target.y`)

It converts the optimized TAC into assembly using register `R0`.

```bash
sed 's/optimizer.tab.h/target.tab.h/' optimizer.l > target.l
```

**target.y**
```yacc
%{
#include <stdio.h>
#include <string.h>
int yylex(void);
void yyerror(const char *s);
char ptemp[32] = "", prel[4] = "";

void binop(const char *r, const char *a, const char *op, const char *b) {
    const char *ins = NULL;
    printf("    ; %s = %s %s %s\n", r, a, op, b);
    if      (!strcmp(op, "+"))  ins = "ADD";
    else if (!strcmp(op, "-"))  ins = "SUB";
    else if (!strcmp(op, "*"))  ins = "MUL";
    else if (!strcmp(op, "/"))  ins = "DIV";
    else if (!strcmp(op, "<<")) ins = "SHL";
    if (ins) { printf("    MOV  R0, %s\n    %s  R0, %s\n    MOV  %s, R0\n", a, ins, b, r); return; }
    printf("    MOV  R0, %s\n    CMP  R0, %s\n", a, b);       /* relational: remember it for next ifFalse */
    strcpy(ptemp, r); strcpy(prel, op);
}
void condjump(const char *c, const char *l) {
    printf("    ; ifFalse %s goto %s\n", c, l);
    if (!strcmp(c, ptemp)) {
        const char *j = !strcmp(prel,"<")  ? "JGE" : !strcmp(prel,">")  ? "JLE" :
                        !strcmp(prel,"<=") ? "JG"  : !strcmp(prel,">=") ? "JL"  :
                        !strcmp(prel,"==") ? "JNE" : "JE";
        printf("    %s  %s\n", j, l); ptemp[0] = 0;
    } else printf("    CMP  %s, 0\n    JE   %s\n", c, l);
}
%}
%union { char str[100]; }
%token <str> ID NUM OP
%token IFFALSE GOTO NL
%type <str> operand
%%
prog : /* empty */ | prog line ;
line : ID ':' NL                    { printf("%s:\n", $1); }
     | ID '=' operand NL            { printf("    ; %s = %s\n    MOV  R0, %s\n    MOV  %s, R0\n", $1, $3, $3, $1); }
     | ID '=' operand OP operand NL { binop($1, $3, $4, $5); }
     | IFFALSE operand GOTO ID NL   { condjump($2, $4); }
     | GOTO ID NL                   { printf("    JMP  %s\n", $2); }
     | NL ;
operand : ID { strcpy($$, $1); } | NUM { strcpy($$, $1); } ;
%%
void yyerror(const char *s) { fprintf(stderr, "TAC syntax error: %s\n", s); }
int main() { if (yyparse()) return 1; printf("    HLT\n"); return 0; }
```
```bash
bison -d -o target.tab.c target.y
flex  -o target.lex.c target.l
gcc target.tab.c target.lex.c -o target
./target < opt.txt
```
Output:
```
    ; t1 = n << 2
    MOV  R0, n
    SHL  R0, 2
    MOV  t1, R0
    ; r = 80
    MOV  R0, 80
    MOV  r, R0
    ; t4 = x * y
    MOV  R0, x
    MUL  R0, y
    MOV  t4, R0
L1:
    ; t2 = m < t1
    MOV  R0, m
    CMP  R0, t1
    ; ifFalse t2 goto L2
    JGE  L2
    ; s = t4 + z
    MOV  R0, t4
    ADD  R0, z
    MOV  s, R0
    ; t = m + s
    MOV  R0, m
    ADD  R0, s
    MOV  t, R0
    JMP  L1
L2:
    HLT
```
**Pattern to memorize:** every `a = b op c` becomes `MOV R0,b` → `OP R0,c` → `MOV a,R0`. `ifFalse` after `<` becomes `CMP` plus the opposite jump (`<` gives `JGE`). For the "one or two statements" requirement, point to `s = x * y + z` and its three lines of assembly.

---

## STEP 6: Run everything with one command (`run.sh`)

```bash
#!/bin/bash
set -e
flex -o lexer1.yy.c lexer.l && gcc lexer1.yy.c -o lexer
for m in syntax tac optimizer target; do
  bison -d -o $m.tab.c $m.y && flex -o $m.lex.c $m.l && gcc $m.tab.c $m.lex.c -o $m
done
mv tac icg 2>/dev/null || true
echo "===== 1. LEXICAL ANALYSIS =====";        ./lexer < input.c
echo "===== 2. SYNTAX ANALYSIS =====";         ./syntax < input.c
echo "===== 3. INTERMEDIATE CODE (TAC) =====";  ./icg < input.c | tee tac.txt
echo "===== 4. OPTIMIZATION =====";            ./optimizer < tac.txt | tee opt.txt
echo "===== 5. TARGET CODE =====";             ./target < opt.txt
```
```bash
chmod +x run.sh && ./run.sh
```
To show a different program, edit `input.c` only. Try the `for` and `if-else` case:
```c
for (i = 0; i < 10; i = i + 1) { if (a > b) x = y * 8; else x = y + 0; }
```
I tested this one too. It generates correct `L1..L4` labels, with the increment `i = i + 1` placed after the body.

---

## Debugging tips (per step)

**Build errors**
- `flex: command not found` means you need `sudo apt install flex bison gcc`.
- `syntax.tab.h: No such file` means you skipped `bison -d` or mistyped `-o`. Always run bison before flex.
- `undefined reference to yywrap` means `%option noyywrap` is missing.

**Step 1 (lexer)**
- No output usually means you ran `./lexer input.c`. Use `./lexer < input.c`.
- A keyword printed as IDENTIFIER means the keyword rule is after the identifier rule.
- Check stray characters such as `;` or `{`. If the separator rule lacks them, you get `LEXICAL ERROR`.

**Step 2 (syntax)**
- `SYNTAX ERROR near line N` means a missing `;`, `)` or `}`. Check line N and the line before it.
- Bison conflict warnings: run `bison -v syntax.y` and read `syntax.output`. The if-else `%nonassoc` lines are what prevent them.

**Step 3 (TAC)**
- Empty output means the parse failed. Run `./syntax < input.c` first.
- Wrong `$n` numbers in mid-rule actions are the usual bug. Count every symbol and every `{ }` mid-action as one position.

**Step 4 (optimizer)**
- `TAC syntax error` usually means `tac.txt` is empty or the last line has no newline. Check with `cat tac.txt`.
- Nothing optimized means the TAC has no matching pattern. Test with `t1 = 2 * 3`.

**Step 5 (target)**
- Use `./target < opt.txt`, not `tac.txt`. `<<` only appears after optimization.
- If `JGE` is wrong, compare with the table in `condjump`.

**Debug-anything tricks**
```bash
./icg < input.c | cat -A      # shows hidden characters
bison -t -o tac.tab.c tac.y   # add #define YYDEBUG 1 and yydebug=1; in main for a parser trace
```

---

## Viva questions

- **Why `-d` in bison?** It generates the `.tab.h` header containing the token numbers, so the lexer and parser agree on them.
- **What is `yylval`?** It carries a token's value from lex to yacc.
- **What does `%union` do?** It defines the type of the semantic values.
- **What is `$$` and what is `$1`?** `$$` is the result of the rule, and `$1` is the value of its first symbol.
- **Why labels and `ifFalse`?** Control flow is flattened into jumps, so a `while` becomes `L1: … ifFalse … goto L1 … L2:`.
- **Why do the temporaries go away?** `t6 = m + s; t = t6` becomes `t = m + s`, because the temp is used only once.

I couldn't see the contents of your uploaded `.l` and `.y` files, so none of the code above is based on them. If you want your own versions fixed, paste one and I'll patch it.