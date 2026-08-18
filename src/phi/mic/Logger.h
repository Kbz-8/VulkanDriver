#ifndef APE_PHI_LOGGER_H
#define APE_PHI_LOGGER_H

typedef enum LogLevel
{
	PHI_LOG_LEVEL_INFO = 0,
	PHI_LOG_LEVEL_WARN = 1,
	PHI_LOG_LEVEL_ERR = 2,
	PHI_LOG_LEVEL_FATAL = 3,
} LogLevel;

static const char* StatusName[] = {
	"OK",
	"Bad Message",
	"Unsupported version",
	"Unsupported packed",
	"Out of memory",
	"Invalid handle",
	"Host memory map failed",
	"Invalid argument",
};

void Log(LogLevel level, const char* fmt, const char* file, const char* function, int line, ...);

#define LogError(msg) Log(PHI_LOG_LEVEL_ERR, msg, __FILE__, __FUNCTION__, __LINE__)
#define LogWarning(msg) Log(PHI_LOG_LEVEL_WARN, msg, __FILE__, __FUNCTION__, __LINE__)
#define LogInfo(msg) Log(PHI_LOG_LEVEL_INFO, msg, __FILE__, __FUNCTION__, __LINE__)
#define LogFatal(msg) Log(PHI_LOG_LEVEL_FATAL, msg, __FILE__, __FUNCTION__, __LINE__)

#define LogErrorFmt(msg, ...) Log(PHI_LOG_LEVEL_ERR, msg, __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__)
#define LogWarningFmt(msg, ...) Log(PHI_LOG_LEVEL_WARN, msg, __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__)
#define LogInfoFmt(msg, ...) Log(PHI_LOG_LEVEL_INFO, msg, __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__)
#define LogFatalFmt(msg, ...) Log(PHI_LOG_LEVEL_FATAL, msg, __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__)

#endif
