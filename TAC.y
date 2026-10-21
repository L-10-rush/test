%{
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
int yylex(void);
void yyerror()
{
	printf("Invalid Syntax!\n");
}
int t=1;
%}

%union {
	char str[20];
}

%token <str> ID NUMBER
%type <str> expr

%left '+' '-'
%left '*' '/'

%%
stmt : ID '=' expr	{printf("%s = %s\n",$1,$3);}
     ;
expr : expr '+' expr	{sprintf($$,"t%d",t);printf("t%d = %s + %s\n",t++,$1,$3);}
     | expr '-' expr	{sprintf($$,"t%d",t);printf("t%d = %s - %s\n",t++,$1,$3);}
    | expr '*' expr	{sprintf($$,"t%d",t);printf("t%d = %s * %s\n",t++,$1,$3);}
    | expr '/' expr	{sprintf($$,"t%d",t);printf("t%d = %s / %s\n",t++,$1,$3);}
     | '('expr')'	{strcpy($$,$2);}
     | ID		{strcpy($$,$1);}
     | NUMBER		{strcpy($$,$1);}
     ;
%%
void main()
{
	printf("Enter an Expression: ");
	yyparse();
}