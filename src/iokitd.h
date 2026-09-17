/*
 This file is part of Darling.

 Copyright (C) 2020 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#ifndef _IOKITD_H
#define _IOKITD_H
#include <mach/mach.h>
#include <CoreFoundation/CFString.h>
#include <sys/types.h>

#define asldebug(...) os_log_debug(OS_LOG_DEFAULT, __VA_ARGS__)

void throwCFStringException(CFStringRef format, ...);
extern mach_port_t g_masterPort, g_deathPort, g_iokitPortSet;

#ifdef __cplusplus
extern "C" {
#endif
// Always-reply interest/notification object. Chrome parks if this MIG is silent.
kern_return_t iokitd_make_interest_notification(mach_port_t service, const char* type,
	mach_port_t wake_port, mach_port_t *notification);
// After the add_interest MIG reply is sent, deliver the first
// kIOServiceMessageNotificationType on the client's wake port.
void iokitd_flush_interest_pings(void);
#ifdef __cplusplus
}
#endif

// iokitd calls only - not valid for powerd!
extern pid_t g_iokitCurrentCallerPID;

#endif

