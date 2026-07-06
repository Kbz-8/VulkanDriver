#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include <Logger.h>

#define RED 31
#define GREEN 32
#define BLUE 34
#define DEF 0
#define BLACK 30
#define YELLOW 33
#define MAGENTA 35
#define CYAN 36
#define WHITE 37
#define BG_RED 41
#define BG_GREEN 42
#define BG_BLUE 44
#define BG_DEF 0
#define BG_BLACK 40
#define BG_YELLOW 43
#define BG_MAGENTA 45
#define BG_CYAN 46
#define BG_WHITE 47
#define RESET 0
#define BOLD 1
#define UNDERLINE 4
#define INVERSE 7
#define BOLD_OFF 21
#define UNDERLINE_OFF 24
#define INVERSE_OFF 27

inline static void SetConsoleColor(FILE* file, int code)
{
	fprintf(file, "\033[1;%dm", code);
}

void PhiLog(PhiLogLevel level, const char* fmt, const char* file, const char* function, int line, ...)
{
	time_t now = time(0);
	struct tm tstruct = *localtime(&now);
	char buffer[128];
	strftime(buffer, sizeof(buffer), "[%X] ", &tstruct);

	FILE* out = stdout;

	if(level != PHI_LOG_LEVEL_INFO)
		out = stderr;

	// Way too much printf calls
	SetConsoleColor(out, MAGENTA);
	fprintf(out, "[Phi device ");
	SetConsoleColor(out, GREEN);
	fprintf(out, "Phi");
	SetConsoleColor(out, YELLOW);
	fprintf(out, "%s", buffer);
	SetConsoleColor(out, MAGENTA);
	fputc(']', out);

	switch(level)
	{
		case PHI_LOG_LEVEL_INFO:
			SetConsoleColor(out, BLUE);
			fprintf(out, "[info] ");
			break;
		case PHI_LOG_LEVEL_WARN:
			SetConsoleColor(out, MAGENTA);
			fprintf(out, "[warn] ");
			break;
		case PHI_LOG_LEVEL_ERR:
		case PHI_LOG_LEVEL_FATAL:
			SetConsoleColor(out, RED);
			fprintf(out, "[err]  ");
			break;
	}

	va_list argptr;
	va_start(argptr, line);

	SetConsoleColor(out, RESET);
	fprintf(out, fmt, argptr);
	fputc('\n', out);

	if(level == PHI_LOG_LEVEL_FATAL)
	{
		SetConsoleColor(out, BG_RED);
		fprintf(out, "Fatal Error: emergency exit\n");
		SetConsoleColor(out, BG_DEF);
		abort();
	}
}
