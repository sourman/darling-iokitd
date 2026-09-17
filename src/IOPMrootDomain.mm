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

#include "IOPMrootDomain.h"
#include "IOUserClient.h"
#include "iokitd.h"
#import <Foundation/NSString.h>
#import <Foundation/NSDictionary.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/IOReturn.h>
#include <IOKit/IOMessage.h>
#include <IOKit/OSMessageNotification.h>
#include <IOKit/pwr_mgt/IOPMLibDefs.h>
#include <os/log.h>
#include <cstring>
#include <vector>
#include <mach/mach.h>
#include <mach/mach_port.h>
#include <mach/message.h>
#include <cstdarg>
#include <cstdio>
#include <dispatch/dispatch.h>

extern "C" {
#include "iokitmigServer.h"
}

static IOPMrootDomain* g_rootDomain;

static void powerLog(const char* fmt, ...);

const char* IOPMrootDomain::className() const
{
	return "IOPMrootDomain";
}

bool IOPMrootDomain::conformsTo(const char* className)
{
	if (strcmp(className, "IOPMrootDomain") == 0)
		return true;
	return IOService::conformsTo(className);
}

NSDictionary* IOPMrootDomain::matchingDictionary()
{
	// IOServiceMatching("IOPMrootDomain") is {IOProviderClass: IOPMrootDomain}.
	return @{
		@"IOProviderClass": @"IOPMrootDomain",
		@"IOClass": @"IOPMrootDomain",
	};
}

NSDictionary* IOPMrootDomain::getProperties()
{
	return @{
		@"IOClass": @"IOPMrootDomain",
		@"IOName": @"IOPMrootDomain",
		@"name": @"IOPMrootDomain",
	};
}

IOPMrootDomain* IOPMrootDomain::instance()
{
	return g_rootDomain;
}

class IOPowerConnectionEntry : public IORegistryEntry
{
public:
	const char* className() const override { return "IOPowerConnection"; }
};

class RootDomainUserClient : public IOUserClient
{
public:
	const char* className() const override { return "RootDomainUserClient"; }
	NSDictionary* matchingDictionary() override
	{
		return @{ @"IOClass": @"RootDomainUserClient" };
	}
	IOExternalMethod *getExternalMethodForIndex(UInt32 index) override;
	IOReturn acknowledgePowerChange(void* p1, void* p2, void* p3, void* p4, void* p5, void* p6);
};

IOExternalMethod *RootDomainUserClient::getExternalMethodForIndex(UInt32 index)
{
	static IOExternalMethod method;
	if (index != kPMAllowPowerChange && index != kPMCancelPowerChange)
		return nullptr;

	method.object = this;
	method.func = IOMethod(&RootDomainUserClient::acknowledgePowerChange);
	method.flags = kIOUCScalarIScalarO;
	method.count0 = 1;
	method.count1 = 0;
	return &method;
}

IOReturn RootDomainUserClient::acknowledgePowerChange(void* p1, void* p2, void* p3, void* p4, void* p5, void* p6)
{
	return kIOReturnSuccess;
}

class IOInterestNotification : public IOObject
{
public:
	// XNU IOServiceMessageUserNotification: a kernel object whose send
	// right is the io_object_t. The client's IONotificationPort is wakePort
	// (MAKE_SEND of that receive right). Keep the notify object off the
	// iokit port set so COPY_SEND in the MIG reply cannot land on the
	// same set we are currently serving.
	IOInterestNotification(mach_port_t wakePort, mach_port_t service,
		const io_user_reference_t* reference, mach_msg_type_number_t referenceCnt)
	: IOObject(false)
	, m_wakePort(wakePort)
	, m_service(service)
	, m_refCnt(0)
	{
		memset(m_ref, 0, sizeof(m_ref));
		if (reference && referenceCnt)
		{
			m_refCnt = referenceCnt > 8 ? 8 : referenceCnt;
			memcpy(m_ref, reference, m_refCnt * sizeof(io_user_reference_t));
		}
	}

	~IOInterestNotification()
	{
		if (MACH_PORT_VALID(m_wakePort))
			mach_port_deallocate(mach_task_self(), m_wakePort);
	}

	const char* className() const override { return "IOUserNotification"; }

	mach_port_t wakePort() const { return m_wakePort; }
	mach_port_t servicePort() const { return m_service; }
	const io_user_reference_t* refs() const { return m_ref; }
	mach_msg_type_number_t refCount() const { return m_refCnt; }

private:
	mach_port_t m_wakePort;
	mach_port_t m_service;
	io_user_reference_t m_ref[8];
	mach_msg_type_number_t m_refCnt;
};

struct PendingInterestPing
{
	mach_port_t wake;
	mach_port_t notify;
	mach_port_t service;
	io_user_reference_t ref[8];
	mach_msg_type_number_t refCnt;
};

static std::vector<PendingInterestPing> g_pendingInterestPings;

#pragma pack(4)
struct InterestPingMsg
{
	mach_msg_header_t hdr;
	OSNotificationHeader64 notify;
	IOServiceInterestContent64 content;
};
#pragma pack()

static void sendInterestPing(const PendingInterestPing& ping)
{
	InterestPingMsg msg;
	memset(&msg, 0, sizeof(msg));

	// Simple (non-complex) kOSNotificationMessageID. CFMachPort is created
	// after add_interest returns; a queued simple msg still wakes it.
	msg.hdr.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
	msg.hdr.msgh_remote_port = ping.wake;
	msg.hdr.msgh_local_port = MACH_PORT_NULL;
	msg.hdr.msgh_size = sizeof(msg);
	msg.hdr.msgh_id = kOSNotificationMessageID;

	msg.notify.size = sizeof(IOServiceInterestContent64);
	msg.notify.type = kIOServiceMessageNotificationType;
	if (ping.refCnt)
		memcpy(msg.notify.reference, ping.ref, ping.refCnt * sizeof(io_user_reference_t));

	msg.content.messageType = kIOMessageServicePropertyChange;
	msg.content.messageArgument[0] = 0;

	kern_return_t kr = mach_msg(&msg.hdr,
		MACH_SEND_MSG | MACH_SEND_TIMEOUT,
		msg.hdr.msgh_size, 0, MACH_PORT_NULL,
		1000, MACH_PORT_NULL);
	os_log(OS_LOG_DEFAULT, "first_interest wake=0x%x notify=0x%x service=0x%x kr=%d size=%u id=%d",
		ping.wake, ping.notify, ping.service, kr, msg.hdr.msgh_size, kOSNotificationMessageID);
	powerLog("first_interest wake=0x%x notify=0x%x service=0x%x kr=%d size=%u",
		ping.wake, ping.notify, ping.service, kr, msg.hdr.msgh_size);
}

void iokitd_flush_interest_pings(void)
{
	for (const PendingInterestPing& ping : g_pendingInterestPings)
	{
		sendInterestPing(ping);
		PendingInterestPing later = ping;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
			dispatch_get_main_queue(), ^{
				sendInterestPing(later);
			});
	}
	g_pendingInterestPings.clear();
}

static void powerLog(const char* fmt, ...)
{
	FILE* f = fopen("/tmp/iokitd-power.log", "a");
	if (!f)
		return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

void IOPMrootDomain::registerSelf(ServiceRegistry* targetServiceRegistry)
{
	IOPowerConnectionEntry* connection = new IOPowerConnectionEntry;
	connection->registerInPlane(kIOPowerPlane, "IOPowerConnection", IORegistryEntry::root());

	if (!g_rootDomain)
		g_rootDomain = new IOPMrootDomain;
	g_rootDomain->registerInPlane(kIOPowerPlane, "IOPMrootDomain", connection);
	g_rootDomain->registerInPlane(kIOServicePlane, "IOPMrootDomain", IORegistryEntry::root());
	targetServiceRegistry->registerService(g_rootDomain);

	os_log(OS_LOG_DEFAULT, "registered IOPower:/IOPowerConnection/IOPMrootDomain port=0x%x",
		g_rootDomain->port());
	powerLog("registered IOPower:/IOPowerConnection/IOPMrootDomain port=0x%x",
		g_rootDomain->port());
}

static void discardOOLProperties(io_buf_ptr_t properties, mach_msg_type_number_t propertiesCnt)
{
	if (properties && propertiesCnt)
		vm_deallocate(mach_task_self(), (vm_address_t) properties, propertiesCnt);
}

kern_return_t is_io_service_open_extended
(
	mach_port_t service,
	task_t owningTask,
	uint32_t connect_type,
	NDR_record_t ndr,
	io_buf_ptr_t properties,
	mach_msg_type_number_t propertiesCnt,
	kern_return_t *result,
	mach_port_t *connection
)
{
	discardOOLProperties(properties, propertiesCnt);

	IOObject* obj = IOObject::lookup(service);
	const char* name = obj ? obj->className() : "unknown";
	os_log(OS_LOG_DEFAULT, "is_io_service_open_extended service=%u class=%s", service, name);
	powerLog("open_extended service=%u class=%s", service, name);

	RootDomainUserClient* client = new RootDomainUserClient;
	// Extra SEND so MIG COPY_SEND (disp 19) still has a right. Do not
	// releaseLater the only send right: that races the reply send on the
	// iokit thread vs dispatch_async(main) and yields MACH_SEND_INVALID_RIGHT.
	client->retain();
	*connection = client->port();
	*result = kIOReturnSuccess;

	mach_port_urefs_t sendRefs = 0;
	mach_port_get_refs(mach_task_self(), *connection, MACH_PORT_RIGHT_SEND, &sendRefs);
	os_log(OS_LOG_DEFAULT, "is_io_service_open_extended connection=0x%x send_refs=%u",
		*connection, sendRefs);
	powerLog("open_extended connection=0x%x send_refs=%u", *connection, sendRefs);
	return KERN_SUCCESS;
}

static kern_return_t addInterestNotification(mach_port_t service, const char* type_of_interest,
	mach_port_t wake_port, const io_user_reference_t* reference,
	mach_msg_type_number_t referenceCnt, mach_port_t *notification)
{
	*notification = MACH_PORT_NULL;

	IOObject* obj = IOObject::lookup(service);
	const char* name = obj ? obj->className() : "unknown";
	const char* type = type_of_interest ? type_of_interest : "";
	os_log(OS_LOG_DEFAULT, "is_io_service_add_interest_notification service=%u class=%s type=%s wake=%u",
		service, name, type, wake_port);
	powerLog("add_interest service=%u class=%s type=%s wake=%u", service, name, type, wake_port);

	// Always reply. Thermal / battery events are optional (Result 9 was
	// previously non-fatal). Parking the MIG send+rcv is fatal.
	try
	{
		IOInterestNotification* notify = new IOInterestNotification(wake_port, service, reference, referenceCnt);
		// Extra SEND so MIG COPY_SEND (disp 19) still has a right.
		notify->retain();
		*notification = notify->port();
		// Stay off the set until this reply is sent, then serve get_class /
		// get_registry_entry_id / conforms_to on the notify object.
		notify->schedulePortSetAttach();
		PendingInterestPing ping;
		memset(&ping, 0, sizeof(ping));
		ping.wake = wake_port;
		ping.notify = notify->port();
		ping.service = service;
		ping.refCnt = notify->refCount();
		if (ping.refCnt)
			memcpy(ping.ref, notify->refs(), ping.refCnt * sizeof(io_user_reference_t));
		g_pendingInterestPings.push_back(ping);
		os_log(OS_LOG_DEFAULT, "add_interest notify=0x%x wake=0x%x", *notification, wake_port);
		powerLog("add_interest notify=0x%x wake=0x%x", *notification, wake_port);
		return KERN_SUCCESS;
	}
	catch (...)
	{
		// Live fallback: COPY_SEND the client's IONotificationPort itself.
		if (MACH_PORT_VALID(wake_port))
		{
			mach_port_mod_refs(mach_task_self(), wake_port, MACH_PORT_RIGHT_SEND, 1);
			*notification = wake_port;
			PendingInterestPing ping;
			memset(&ping, 0, sizeof(ping));
			ping.wake = wake_port;
			ping.notify = wake_port;
			ping.service = service;
			g_pendingInterestPings.push_back(ping);
			powerLog("add_interest fallback wake=0x%x as notify", wake_port);
			return KERN_SUCCESS;
		}
		powerLog("add_interest failed, still replying null");
		return KERN_SUCCESS;
	}
}

kern_return_t is_io_service_add_interest_notification
(
	mach_port_t service,
	io_name_t type_of_interest,
	mach_port_t wake_port,
	io_async_ref_t reference,
	mach_msg_type_number_t referenceCnt,
	mach_port_t *notification
)
{
	io_user_reference_t ref64[8];
	memset(ref64, 0, sizeof(ref64));
	mach_msg_type_number_t n = referenceCnt > 8 ? 8 : referenceCnt;
	for (mach_msg_type_number_t i = 0; i < n; i++)
		ref64[i] = reference ? (io_user_reference_t)reference[i] : 0;
	return addInterestNotification(service, type_of_interest, wake_port, ref64, n, notification);
}

kern_return_t is_io_service_add_interest_notification_64
(
	mach_port_t service,
	io_name_t type_of_interest,
	mach_port_t wake_port,
	io_async_ref64_t reference,
	mach_msg_type_number_t referenceCnt,
	mach_port_t *notification
)
{
	return addInterestNotification(service, type_of_interest, wake_port, reference, referenceCnt, notification);
}

kern_return_t iokitd_make_interest_notification(mach_port_t service, const char* type,
	mach_port_t wake_port, mach_port_t *notification)
{
	return addInterestNotification(service, type, wake_port, nullptr, 0, notification);
}
