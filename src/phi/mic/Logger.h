#ifndef APE_PHI_LOGGER_H
#define APE_PHI_LOGGER_H

typedef enum PhiLogLevel
{
	PHI_LOG_LEVEL_INFO = 0,
	PHI_LOG_LEVEL_WARN = 1,
	PHI_LOG_LEVEL_ERR = 2,
	PHI_LOG_LEVEL_FATAL = 3,
} PhiLogLevel;

void PhiLog(PhiLogLevel level, const char* fmt, const char* file, const char* function, int line, ...);

#define PhiLogError(msg) PhiLog(PHI_LOG_LEVEL_ERR, msg, __FILE__, __FUNCTION__, __LINE__)
#define PhiLogWarning(msg) PhiLog(PHI_LOG_LEVEL_WARN, msg, __FILE__, __FUNCTION__, __LINE__)
#define PhiLogInfo(msg) PhiLog(PHI_LOG_LEVEL_INFO, msg, __FILE__, __FUNCTION__, __LINE__)
#define PhiLogFatal(msg) PhiLog(PHI_LOG_LEVEL_FATAL, msg, __FILE__, __FUNCTION__, __LINE__)

#define PhiLogErrorFmt(msg, ...) PhiLog(PHI_LOG_LEVEL_ERR, msg, __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__)
#define PhiLogWarningFmt(msg, ...) PhiLog(PHI_LOG_LEVEL_WARN, msg, __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__)
#define PhiLogInfoFmt(msg, ...) PhiLog(PHI_LOG_LEVEL_INFO, msg, __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__)
#define PhiLogFatalFmt(msg, ...) PhiLog(PHI_LOG_LEVEL_FATAL, msg, __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__)

#endif
