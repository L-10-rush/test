%{
#include <stdio.h>
#include <string.h>
int yylex(void);
void yyerror(const char *s)
{
	printf("Invalid Syntax!\n");
}
int reg=0;
char r[10];
%}

%union {
	char str[100];
}

%token <str> ID NUMBER
%type <str> expr

%left '+' '-'
%left '*' '/'

%%
stmt : ID '=' expr {printf("MOV %s, %s\n",$1,$3);}
     ;
expr : expr '+' expr {sprintf(r,"R%d",reg++);printf("ADD %s, %s, %s\n",r,$1,$3);strcpy($$,r);}
expr : expr '-' expr {sprintf(r,"R%d",reg++);printf("SUB %s, %s, %s\n",r,$1,$3);strcpy($$,r);}
expr : expr '*' expr {sprintf(r,"R%d",reg++);printf("MUL %s, %s, %s\n",r,$1,$3);strcpy($$,r);}
expr : expr '/' expr {sprintf(r,"R%d",reg++);printf("DIV %s, %s, %s\n",r,$1,$3);strcpy($$,r);}
expr : '('expr')'    {strcpy($$,$2);}
expr : ID	     {strcpy($$,$1);}
expr : NUMBER	     {strcpy($$,$1);}
     ;
%%
void main()
{
	printf("Enter an Expression: ");
	yyparse();
}