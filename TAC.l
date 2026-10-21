%{
#include "y.tab.h"
#include <string.h>
#include <stdlib.h>
%}
%%
[0-9]+		{strcpy(yylval.str,yytext);return NUMBER;}
[a-zA-Z]+	{strcpy(yylval.str,yytext);return ID;}
[+\-*/()=]	{return yytext[0];}
[ \t\n]		;
.		{return yytext[0];}
%%
int yywrap()
{
	return 1;
}