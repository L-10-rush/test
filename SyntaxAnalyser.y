%{
#include <stdio.h>
int yylex(void);
void yyerror()
{
	printf("Invalid Syntax!\n");
}
%}

%token ID NUMBER
%left '+' '-'
%left '*' '/'

%%
stmt : ID '=' expr
     ;
expr : expr '+' expr
     | expr '-' expr
     | expr '*' expr
     | expr '/' expr
     | '('expr')'
     | ID
     | NUMBER
     ;
%%
void main()
{
	printf("Enter an Expression: ");
	if(yyparse()==0)
	{
		printf("Valid Syntax!\n");
	}
}