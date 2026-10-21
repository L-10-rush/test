%{
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
int yylex(void);
void yyerror()
{
	printf("Invalid Syntax!\n");
}
%}

%union {
	char str[1000];
}

%token <str> ID NUMBER
%type <str> expr

%left '+' '-'
%left '*' '/'

%%
stmt : ID '=' expr	{printf("%s = %s\n",$1,$3);}
     ;
expr : expr '+' expr	{if(isdigit($1[0]) && isdigit($3[0]))
			{
				sprintf($$,"%d",atoi($1)+atoi($3));
			}
			else
			{
				sprintf($$,"%s + %s",$1,$3);
			}
			}

     | expr '-' expr	{if(isdigit($1[0]) && isdigit($3[0]))
			{
				sprintf($$,"%d",atoi($1)-atoi($3));
			}
			else
			{
				sprintf($$,"%s - %s",$1,$3);
			}
			}
    | expr '*' expr	{if(isdigit($1[0]) && isdigit($3[0]))
			{
				sprintf($$,"%d",atoi($1)*atoi($3));
			}
			else
			{
				sprintf($$,"%s * %s",$1,$3);
			}
			}
    | expr '/' expr	{if(isdigit($1[0]) && isdigit($3[0]))
			{
				sprintf($$,"%d",atoi($1)/atoi($3));
			}
			else
			{
				sprintf($$,"%s / %s",$1,$3);
			}
			}
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