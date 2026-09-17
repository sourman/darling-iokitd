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

#include "iokitd.h"
#include "ServiceRegistry.h"
#include "IOPlatformExpertDevice.h"
#include "IOPMrootDomain.h"
#include <IOKit/IOCFUnserialize.h>
#include <CoreFoundation/CFString.h>
#import <Foundation/NSString.h>
#import <Foundation/NSDictionary.h>
#include <IOKit/IOReturn.h>
#include <os/log.h>
#include <stdexcept>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdarg.h>
#include "IOIterator.h"

extern "C" {
#include "iokitmigServer.h"
}

ServiceRegistry* ServiceRegistry::instance()
{
	static ServiceRegistry reg;
	return &reg;
}

IOIterator* ServiceRegistry::iteratorForMatchingServices(NSDictionary* criteria) const
{
	std::vector<IOObject*> matching;

	for (auto it = m_registeredServices.begin(); it != m_registeredServices.end(); it++)
	{
		if ((*it)->matches(criteria))
			matching.push_back(*it);
	}

	return new IOIterator(matching);
}

IOService* ServiceRegistry::firstMatchingService(NSDictionary* criteria) const
{
	for (auto it = m_registeredServices.begin(); it != m_registeredServices.end(); it++)
	{
		if ((*it)->matches(criteria))
			return *it;
	}
	return nullptr;
}

void ServiceRegistry::registerService(IOService* service)
{
	m_registeredServices.push_back(service);
}

kern_return_t is_io_service_get_matching_services_ool
(
	mach_port_t master_port,
	io_buf_ptr_t matching,
	mach_msg_type_number_t matchingCnt,
	kern_return_t *result,
	mach_port_t *existing
)
{
	// TODO
    return kIOReturnUnsupported;
}

kern_return_t is_io_service_get_matching_services_bin
(
	mach_port_t master_port,
	io_struct_inband_t matching,
	mach_msg_type_number_t matchingCnt,
	mach_port_t *existing
)
{
	CFStringRef errorString = nullptr;
	try
	{
		CFTypeRef criteria = IOCFUnserializeBinary(matching, matchingCnt, nullptr, 0, &errorString);

		if (!criteria)
			throwCFStringException(CFSTR("io_service_get_matching_services_bin(): cannot parse 'matching': %@"), errorString);
		
		if (CFGetTypeID(criteria) != CFDictionaryGetTypeID())
			throw std::runtime_error("io_service_get_matching_services_bin(): dictionary expected");

		// Criteria example:
		// IOProviderClass -> IODisplayConnect
		IOIterator* iterator = ServiceRegistry::instance()->iteratorForMatchingServices((NSDictionary*) criteria);
		CFShow(criteria);
		CFRelease(criteria);

		*existing = iterator->port();
		iterator->retain();
		iterator->releaseLater();

		return kIOReturnSuccess;
	}
	catch (const std::exception& e)
	{
		os_log_error(OS_LOG_DEFAULT, "is_io_service_get_matching_services_bin: %s", e.what());
		if (errorString)
			CFRelease(errorString);

		return kIOReturnBadArgument;
	}
}

static void matchingLog(const char* fmt, ...)
{
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (n > 0)
	{
		if (n > (int)sizeof(buf))
			n = (int)sizeof(buf);
		(void)write(STDERR_FILENO, buf, (size_t)n);
	}
}

static void logMatchingBlob(const char* matching, mach_msg_type_number_t matchingCnt)
{
	matchingLog("iokitd matching blob cnt=%u", matchingCnt);
	size_t i = 0;
	while (i < matchingCnt)
	{
		unsigned char c = (unsigned char)matching[i];
		if (c >= 0x20 && c < 0x7f)
		{
			size_t j = i;
			while (j < matchingCnt)
			{
				unsigned char d = (unsigned char)matching[j];
				if (d < 0x20 || d >= 0x7f)
					break;
				j++;
			}
			if (j - i >= 4)
				matchingLog(" \"%.*s\"", (int)(j - i), matching + i);
			i = j;
		}
		else
			i++;
	}
	matchingLog("\n");

	size_t dump = matchingCnt;
	if (dump > 96)
		dump = 96;
	matchingLog("iokitd matching hex=");
	for (size_t n = 0; n < dump; n++)
		matchingLog("%02x", (unsigned char)matching[n]);
	matchingLog("\n");
}

static void logMatchingDict(CFTypeRef criteria)
{
	if (!criteria)
	{
		matchingLog("iokitd matching dict=null\n");
		return;
	}
	if (CFGetTypeID(criteria) != CFDictionaryGetTypeID())
	{
		matchingLog("iokitd matching not-dict type=%lu\n",
			(unsigned long)CFGetTypeID(criteria));
		return;
	}

	NSDictionary* dict = (NSDictionary*)criteria;
	NSString* desc = [dict description];
	matchingLog("iokitd matching dict=%s\n", desc ? [desc UTF8String] : "(nil)");
	for (NSString* key in dict)
	{
		NSObject* val = dict[key];
		NSString* vs = [val description];
		matchingLog("iokitd matching key=%s val=%s\n",
			[key UTF8String], vs ? [vs UTF8String] : "(nil)");
	}
}

static mach_port_t portForClassHint(const char* matching, mach_msg_type_number_t matchingCnt)
{
	struct ClassHint {
		const char* name;
		size_t len;
	};
	// Longer names first so AppleBacklightDisplay wins over AppleBacklight.
	static const ClassHint hints[] = {
		{ "IOPlatformExpertDevice", 22 },
		{ "AppleBacklightDisplay", 21 },
		{ "IODisplayConnect", 16 },
		{ "IOPMPowerSource", 15 },
		{ "IOPMrootDomain", 14 },
		{ "AppleBacklight", 14 },
		{ "IOFramebuffer", 13 },
		{ "IOAccelerator", 13 },
		{ "AppleSMC", 8 },
	};
	for (size_t i = 0; i < sizeof(hints) / sizeof(hints[0]); i++)
	{
		if (matchingCnt < hints[i].len)
			continue;
		if (memmem(matching, matchingCnt, hints[i].name, hints[i].len) == nullptr)
			continue;
		NSString* cls = [NSString stringWithUTF8String: hints[i].name];
		NSDictionary* criteria = @{ @"IOProviderClass": cls };
		IOService* svc = ServiceRegistry::instance()->firstMatchingService(criteria);
		matchingLog("iokitd matching hint=%s port=0x%x\n",
			hints[i].name, svc ? svc->port() : 0);
		if (svc)
			return svc->port();
	}
	return MACH_PORT_NULL;
}

static mach_port_t portForMatchingBlob(const char* matching, mach_msg_type_number_t matchingCnt)
{
	logMatchingBlob(matching, matchingCnt);

	if (matching && matchingCnt >= 22 &&
		memmem(matching, matchingCnt, "IOPlatformExpertDevice", 22) != nullptr)
	{
		IOPlatformExpertDevice* expert = IOPlatformExpertDevice::instance();
		if (expert)
			return expert->port();
	}

	if (matching && matchingCnt >= 14 &&
		memmem(matching, matchingCnt, "IOPMrootDomain", 14) != nullptr)
	{
		IOPMrootDomain* domain = IOPMrootDomain::instance();
		if (domain)
			return domain->port();
	}

	if (!matching || matchingCnt == 0)
		return MACH_PORT_NULL;

	CFStringRef errorString = nullptr;
	CFTypeRef criteria = IOCFUnserializeBinary(matching, matchingCnt, nullptr, 0, &errorString);
	if (!criteria)
	{
		matchingLog("iokitd matching unserialize failed\n");
		if (errorString)
		{
			matchingLog("iokitd matching unserialize err=%s\n",
				CFStringGetCStringPtr(errorString, kCFStringEncodingUTF8));
			CFRelease(errorString);
		}
		return portForClassHint(matching, matchingCnt);
	}
	logMatchingDict(criteria);
	if (CFGetTypeID(criteria) != CFDictionaryGetTypeID())
	{
		CFRelease(criteria);
		return portForClassHint(matching, matchingCnt);
	}

	IOService* svc = ServiceRegistry::instance()->firstMatchingService((NSDictionary*)criteria);
	mach_port_t port = svc ? svc->port() : MACH_PORT_NULL;
	matchingLog("iokitd matching first=%s port=0x%x\n",
		svc ? svc->className() : "none", port);
	CFRelease(criteria);
	if (port != MACH_PORT_NULL)
		return port;
	return portForClassHint(matching, matchingCnt);
}

kern_return_t is_io_service_get_matching_service_bin
(
	mach_port_t master_port,
	io_struct_inband_t matching,
	mach_msg_type_number_t matchingCnt,
	mach_port_t *service
)
{
	matchingLog("iokitd matching_service_bin enter cnt=%u\n", matchingCnt);
	*service = portForMatchingBlob(matching, matchingCnt);
	matchingLog("iokitd matching_service_bin port=0x%x\n", *service);
	return kIOReturnSuccess;
}

kern_return_t is_io_service_get_matching_service_ool
(
	mach_port_t master_port,
	io_buf_ptr_t matching,
	mach_msg_type_number_t matchingCnt,
	kern_return_t *result,
	mach_port_t *service
)
{
	matchingLog("iokitd matching_service_ool enter cnt=%u\n", matchingCnt);
	*service = portForMatchingBlob(matching, matchingCnt);
	*result = kIOReturnSuccess;
	matchingLog("iokitd matching_service_ool port=0x%x\n", *service);
	return kIOReturnSuccess;
}

kern_return_t is_io_service_get_matching_services
(
	mach_port_t master_port,
	io_string_t matching,
	mach_port_t *existing
)
{
    // Old unsupported API
    return kIOReturnUnsupported;
}
