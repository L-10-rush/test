%{
#include <stdio.h>
%}
%%
[0-9]+		{printf("NUMBER: %s\n",yytext);}
[a-zA-Z]+	{printf("IDENTIFIER: %s\n",yytext);}
[+\-*/()=]	{printf("OPERATOR: %s\n",yytext);}
[ \t\n]		;
.		{printf("INVALID: %s\n",yytext);}
%%
void main()
{
	printf("Enter an Expression: ");
	yylex();
}
int yywrap()
{
	return 1;
}