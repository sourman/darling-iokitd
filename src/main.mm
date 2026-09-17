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

#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#include <os/log.h>
#include <liblaunch/bootstrap.h>
#include <dispatch/dispatch.h>
#include <dispatch/private.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/pwr_mgt/IOPMLibPrivate.h>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <signal.h>
#include <pthread.h>
#include <mach/message.h>
#include <mach/mach_port.h>
#include <mach/mig_errors.h>
#include "iokitd.h"
#include "iokitmig.h"
#include "IOObject.h"
#include "IODisplayConnectX11.h"
#include "PowerAssertions.h"
#include "IOSurfaceRoot.h"
#include "IOPMrootDomain.h"
#include "IOPlatformExpertDevice.h"

extern "C" {
#include "iokitmigServer.h"
#include "powermanagementServer.h"
}

static const char* SERVICE_NAME = "org.darlinghq.iokitd";
mach_port_t g_masterPort, g_deathPort, g_powerManagementPort, g_iokitPortSet;

static int g_migLogFd = -1;
static const mach_msg_size_t kIokitMaxMsg = 64 * 1024;

static void discoverAllDevices();
static boolean_t iokitSaveAuditTrail(mach_msg_header_t *message, mach_msg_header_t *reply);
static void* iokitMasterLoop(void*);
static void* iokitPowerLoop(void*);

static void iokitMigLog(const char* fmt, ...)
{
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (n <= 0)
		return;
	if (n > (int)sizeof(buf))
		n = (int)sizeof(buf);
	if (g_migLogFd >= 0)
		(void)write(g_migLogFd, buf, (size_t)n);
	(void)write(STDERR_FILENO, buf, (size_t)n);
}

int main(int argc, const char** argv)
{
	mach_port_t bs;
	kern_return_t ret;
	FILE *bootlog = fopen("/tmp/iokitd-boot.log", "a");
	if (bootlog) {
		fprintf(bootlog, "iokitd main pid=%d\n", getpid());
		fflush(bootlog);
	}
	fprintf(stderr, "iokitd main pid=%d\n", getpid());
	fflush(stderr);

	signal(SIGPIPE, SIG_IGN);
	g_migLogFd = open("/tmp/iokitd-mig.log", O_WRONLY | O_CREAT | O_APPEND, 0644);

	ret = bootstrap_check_in(bootstrap_port, SERVICE_NAME, &g_masterPort);

	if (ret != KERN_SUCCESS)
	{
		fprintf(stderr, "bootstrap_check_in(%s) failed %d\n", SERVICE_NAME, ret);
		fflush(stderr);
		if (bootlog) {
			fprintf(bootlog, "bootstrap_check_in(%s) failed %d\n", SERVICE_NAME, ret);
			fflush(bootlog);
			fclose(bootlog);
		}
		os_log_error(OS_LOG_DEFAULT, "%d bootstrap_check_in(%s) failed with error %d", getpid(), SERVICE_NAME, ret);
		return 1;
	}
	if (bootlog) {
		fprintf(bootlog, "check_in ok master=%d\n", g_masterPort);
		fflush(bootlog);
	}

	ret = bootstrap_check_in(bootstrap_port, kIOPMServerBootstrapName, &g_powerManagementPort);

	if (ret != KERN_SUCCESS)
	{
		fprintf(stderr, "bootstrap_check_in(%s) failed %d\n", kIOPMServerBootstrapName, ret);
		fflush(stderr);
		if (bootlog) {
			fprintf(bootlog, "bootstrap_check_in(%s) failed %d\n", kIOPMServerBootstrapName, ret);
			fflush(bootlog);
		}
		os_log_error(OS_LOG_DEFAULT, "%d bootstrap_check_in(%s) failed with error %d", getpid(), kIOPMServerBootstrapName, ret);
		return 1;
	}

	ret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_deathPort);
	if (ret != KERN_SUCCESS)
	{
		os_log_error(OS_LOG_DEFAULT, "%d failed to allocate notification port: %d", getpid(), ret);
		return 1;
	}

	ret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &g_iokitPortSet);
	if (ret != KERN_SUCCESS)
	{
		os_log_error(OS_LOG_DEFAULT, "%d failed to allocate iokit port set: %d", getpid(), ret);
		return 1;
	}
	ret = mach_port_move_member(mach_task_self(), g_masterPort, g_iokitPortSet);
	if (ret != KERN_SUCCESS)
	{
		os_log_error(OS_LOG_DEFAULT, "%d failed to add master port to set: %d", getpid(), ret);
		return 1;
	}
	// Serve NO_SENDERS on the voucher-free master loop. A DISPATCH_SOURCE
	// MACH_RECV here is fake-fired every 50ms by libdispatch skip-kevent
	// poll, and dispatch_mig_server() then SIGSEGVs on the empty port.
	ret = mach_port_move_member(mach_task_self(), g_deathPort, g_iokitPortSet);
	if (ret != KERN_SUCCESS)
	{
		os_log_error(OS_LOG_DEFAULT, "%d failed to add death port to set: %d", getpid(), ret);
		return 1;
	}
	fprintf(stderr, "iokitd port set=0x%x master=0x%x death=0x%x\n", g_iokitPortSet, g_masterPort, g_deathPort);
	fflush(stderr);

	// Build IOKit registry here
	discoverAllDevices();
	initPM();

	////////////////////////////////
	// IOKit + power Mach servers //
	////////////////////////////////
	// Darling's dispatch MACH_RECV source does not wake for launchd
	// check-in ports. mach_msg_server() always ORs MACH_RCV_VOUCHER, which
	// makes 2880 COMPLEX; the generated MIG check then skips the handler
	// and the combined send+rcv never returns. Use a plain mach_msg loop.
	pthread_t iokitThread, powerThread;
	if (pthread_create(&iokitThread, nullptr, iokitMasterLoop, nullptr) != 0)
	{
		os_log_error(OS_LOG_DEFAULT, "%d pthread_create() failed for IOKit MIG", getpid());
		return 1;
	}
	pthread_detach(iokitThread);
	if (pthread_create(&powerThread, nullptr, iokitPowerLoop, nullptr) != 0)
	{
		os_log_error(OS_LOG_DEFAULT, "%d pthread_create() failed for power MIG", getpid());
		return 1;
	}
	pthread_detach(powerThread);

	////////////////////////////////
	// unused port notifications  //
	////////////////////////////////
	// g_deathPort is in g_iokitPortSet (iokitMasterLoop). Do not arm a
	// DISPATCH_SOURCE_TYPE_MACH_RECV: libdispatch skip-kevent poll
	// fake-fires it every 50ms and dispatch_mig_server SIGSEGVs.

	os_log(OS_LOG_DEFAULT, "iokitd up and running.");
	if (bootlog) {
		fprintf(bootlog, "iokitd serving master=%d pwr=%d\n", g_masterPort, g_powerManagementPort);
		fflush(bootlog);
		fclose(bootlog);
		bootlog = nullptr;
	}

	dispatch_main();
	return 0;
}

static void* iokitMasterLoop(void*)
{
	iokitMigLog("iokitd master loop portset=%d master=%d\n", g_iokitPortSet, g_masterPort);
	mach_msg_header_t* request = (mach_msg_header_t*)calloc(1, kIokitMaxMsg);
	mach_msg_header_t* reply = (mach_msg_header_t*)calloc(1, kIokitMaxMsg);
	if (!request || !reply)
	{
		iokitMigLog("iokitd master loop alloc failed\n");
		return nullptr;
	}
	for (;;)
	{
		memset(request, 0, sizeof(mach_msg_header_t));
		kern_return_t mr = mach_msg(request, MACH_RCV_MSG, 0, kIokitMaxMsg, g_iokitPortSet,
			MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
		if (mr != MACH_MSG_SUCCESS)
		{
			iokitMigLog("iokitd master rcv mr=0x%x\n", mr);
			continue;
		}
		memset(reply, 0, sizeof(mach_msg_header_t) + 32);
		if (request->msgh_local_port == g_deathPort)
		{
			(void)IOObject::deathNotify(request, reply);
			iokitMigLog("iokitd deathNotify id=%d bits=0x%x local=%u reply_port=%u\n",
				request->msgh_id, request->msgh_bits,
				request->msgh_local_port, reply->msgh_remote_port);
		}
		else
		{
			(void)iokitSaveAuditTrail(request, reply);
			if (reply->msgh_remote_port == MACH_PORT_NULL && request->msgh_remote_port != MACH_PORT_NULL)
			{
				// Hole IDs (2815 io_service_open, 2835) have a NULL stub.
				// Returning without a send parks Chrome's mach_msg SEND|RCV.
				mig_reply_error_t* err = (mig_reply_error_t*)reply;
				err->Head.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(request->msgh_bits), 0);
				err->Head.msgh_remote_port = request->msgh_remote_port;
				err->Head.msgh_local_port = MACH_PORT_NULL;
				err->Head.msgh_id = request->msgh_id + 100;
				err->Head.msgh_size = sizeof(mig_reply_error_t);
				err->NDR = NDR_record;
				err->RetCode = KERN_SUCCESS;
				iokitMigLog("iokitd demux SYNTH id=%d reply_port=%u\n",
					request->msgh_id, request->msgh_remote_port);
			}
		}
		if (reply->msgh_remote_port == MACH_PORT_NULL)
			continue;
		mach_msg_option_t opts = MACH_SEND_MSG;
		if (MACH_MSGH_BITS_REMOTE(reply->msgh_bits) != MACH_MSG_TYPE_MOVE_SEND_ONCE)
			opts |= MACH_SEND_TIMEOUT;
		mr = mach_msg(reply, opts, reply->msgh_size, 0, MACH_PORT_NULL,
			MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
		iokitMigLog("iokitd master send id=%d mr=0x%x size=%u bits=0x%x\n",
			reply->msgh_id, mr, reply->msgh_size, reply->msgh_bits);
		IOObject::flushPortSetAttaches();
		iokitd_flush_interest_pings();
	}
}

static void* iokitPowerLoop(void*)
{
	if (FILE* f = fopen("/tmp/iokitd-boot.log", "a")) {
		fprintf(f, "mach_msg_server power=%d\n", g_powerManagementPort);
		fclose(f);
	}
	mach_msg_server(powermanagement_server, _powermanagement_subsystem.maxsize, g_powerManagementPort,
		MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT));
	return nullptr;
}

static boolean_t iokitSaveAuditTrail(mach_msg_header_t *message, mach_msg_header_t *reply)
{
	iokitMigLog("iokitd demux id=%d bits=0x%x remote=%u local=%u size=%u\n",
		message->msgh_id, message->msgh_bits,
		message->msgh_remote_port, message->msgh_local_port, message->msgh_size);
	// Skip audit trailers. Requesting MACH_RCV_TRAILER_AUDIT + MACH_RCV_VOUCHER
	// made 2880 COMPLEX; the stub never called matching_service_bin.
	g_iokitCurrentCallerPID = 0;
	mig_routine_t stub = iokit_server_routine(message);
	iokitMigLog("iokitd demux stub=%p\n", stub);
	boolean_t ok = false;
	if (stub)
		ok = iokit_server(message, reply);
	else
		iokitMigLog("iokitd demux NO STUB id=%d (hole 2815/2835 or out of range)\n",
			message->msgh_id);
	iokitMigLog("iokitd demux done id=%d ok=%d reply_bits=0x%x reply_size=%u reply_port=%u\n",
		message->msgh_id, ok, reply->msgh_bits, reply->msgh_size, reply->msgh_remote_port);
	return ok;
}

static void discoverAllDevices()
{
	ServiceRegistry* registry = ServiceRegistry::instance();
	// Trick to make sure the root object gets instantiated first and gets the lowest ID
	IORegistryEntry::root();
	// macOS always has this nub; Chrome's first IOKit lookup is IOPlatformExpertDevice.
	IOPlatformExpertDevice::registerSelf(registry);
	IODisplayConnectX11::discoverDevices(registry);
	IOSurfaceRoot::registerSelf(registry);
	IOPMrootDomain::registerSelf(registry);
	publishChromeIOKitServices(registry);
}
