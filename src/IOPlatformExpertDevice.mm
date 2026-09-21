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

#include "IOPlatformExpertDevice.h"
#import <Foundation/NSString.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSNumber.h>
#include <IOKit/IOKitKeys.h>
#include <cstdio>
#include <cstring>
#include <vector>

static IOPlatformExpertDevice* g_platformExpertDevice;

static NSData* deviceTreeCString(const char* value)
{
	// Device-tree "model" / "compatible" are OSData with a trailing NUL, as on XNU.
	return [NSData dataWithBytes: value length: strlen(value) + 1];
}

static NSData* pciU32(uint32_t value)
{
	// IOPCIFamily publishes vendor-id / device-id as OSData of 4 bytes.
	// Chromium gpu_info_collector_mac reads them with CFDataGetBytePtr.
	return [NSData dataWithBytes: &value length: sizeof(value)];
}

const char* IOPlatformExpertDevice::className() const
{
	return "IOPlatformExpertDevice";
}

bool IOPlatformExpertDevice::conformsTo(const char* className)
{
	if (strcmp(className, "IOPlatformExpertDevice") == 0)
		return true;
	return IOService::conformsTo(className);
}

NSDictionary* IOPlatformExpertDevice::matchingDictionary()
{
	return @{
		@"IOProviderClass": @"IOPlatformExpertDevice",
		@"IOClass": @"IOPlatformExpertDevice",
	};
}

NSDictionary* IOPlatformExpertDevice::getProperties()
{
	return @{
		@"IOClass": @"IOPlatformExpertDevice",
		@"IOName": @"IOPlatformExpertDevice",
		@"name": @"IOPlatformExpertDevice",
		@"compatible": deviceTreeCString("MacBookPro16,1"),
		@"model": deviceTreeCString("MacBookPro16,1"),
		@"board-id": deviceTreeCString("Mac-E7203C0F68AA0004"),
		@"manufacturer": deviceTreeCString("Apple Inc."),
		@"product-name": @"MacBook Pro",
		@"serial-number": deviceTreeCString("C02DLNG000001"),
		@kIOPlatformSerialNumberKey: @"C02DLNG000001",
		@kIOPlatformUUIDKey: @"A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
	};
}

IOPlatformExpertDevice* IOPlatformExpertDevice::instance()
{
	return g_platformExpertDevice;
}

void IOPlatformExpertDevice::registerSelf(ServiceRegistry* targetServiceRegistry)
{
	if (!g_platformExpertDevice)
		g_platformExpertDevice = new IOPlatformExpertDevice;

	g_platformExpertDevice->registerInPlane(kIOServicePlane, "IOPlatformExpertDevice", IORegistryEntry::root());
	targetServiceRegistry->registerService(g_platformExpertDevice);

	fprintf(stderr, "iokitd registered IOPlatformExpertDevice port=0x%x\n",
		g_platformExpertDevice->port());
	fflush(stderr);
}

class PublishedIOService : public IOService
{
public:
	PublishedIOService(const char* className, NSDictionary* props)
	: m_className(className)
	{
		m_props = props ? [props retain] : nil;
	}

	~PublishedIOService()
	{
		[m_props release];
	}

	const char* className() const override { return m_className; }

	NSDictionary* matchingDictionary() override
	{
		NSString* n = [NSString stringWithUTF8String: m_className];
		return @{ @"IOProviderClass": n, @"IOClass": n };
	}

	NSDictionary* getProperties() override
	{
		if (m_props)
			return m_props;
		NSString* n = [NSString stringWithUTF8String: m_className];
		return @{ @"IOClass": n, @"IOName": n, @"name": n };
	}

	bool conformsTo(const char* className) override
	{
		if (strcmp(className, m_className) == 0)
			return true;
		return IOService::conformsTo(className);
	}

private:
	const char* m_className;
	NSDictionary* m_props;
};

static void publishNamedService(ServiceRegistry* targetServiceRegistry,
	const char* className, IORegistryEntry* parent, NSDictionary* props)
{
	PublishedIOService* svc = new PublishedIOService(className, props);
	IORegistryEntry* p = parent ? parent : IORegistryEntry::root();
	svc->registerInPlane(kIOServicePlane, className, p);
	targetServiceRegistry->registerService(svc);
	fprintf(stderr, "iokitd registered %s port=0x%x\n", className, svc->port());
	fflush(stderr);
}

void publishChromeIOKitServices(ServiceRegistry* targetServiceRegistry)
{
	IORegistryEntry* parent = IOPlatformExpertDevice::instance();
	if (!parent)
		parent = IORegistryEntry::root();

	// Desktop Mac: AC attached, no battery. Chrome treats missing
	// IOPMPowerSource as expected on desktops, but still looks it up.
	NSDictionary* powerSourceProps = @{
		@"IOClass": @"IOPMPowerSource",
		@"IOName": @"IOPMPowerSource",
		@"name": @"IOPMPowerSource",
		@"BatteryInstalled": @NO,
		@"ExternalConnected": @YES,
		@"IsCharging": @NO,
		@"CurrentCapacity": @100,
		@"MaxCapacity": @100,
		@"DesignCapacity": @100,
		@"AppleRawCurrentCapacity": @100,
		@"AppleRawMaxCapacity": @100,
		@"TimeRemaining": @65535,
		@"Voltage": @12600,
		@"CycleCount": @0,
		@"Power Source State": @"AC Power",
		@"Transport Type": @"AC",
	};
	publishNamedService(targetServiceRegistry, "IOPMPowerSource", parent, powerSourceProps);

	NSDictionary* framebufferProps = @{
		@"IOClass": @"IOFramebuffer",
		@"IOName": @"IOFramebuffer",
		@"name": @"IOFramebuffer",
		@"IOFBCurrentPixelClock": @0,
		@"IOFBCurrentPixelCount": @0,
	};
	publishNamedService(targetServiceRegistry, "IOFramebuffer", parent, framebufferProps);

	NSDictionary* backlightProps = @{
		@"IOClass": @"AppleBacklight",
		@"IOName": @"AppleBacklight",
		@"name": @"AppleBacklight",
		@"brightness": @1.0,
	};
	publishNamedService(targetServiceRegistry, "AppleBacklight", parent, backlightProps);

	publishNamedService(targetServiceRegistry, "IOAccelerator", parent, nil);
	publishNamedService(targetServiceRegistry, "AppleBacklightDisplay", parent, nil);

	NSDictionary* graphicsAccelProps = @{
		@"IOClass": @"IOGraphicsAccelerator2",
		@"IOName": @"IOGraphicsAccelerator2",
		@"name": @"IOGraphicsAccelerator2",
		@"model": deviceTreeCString("Mesa"),
		@"IOGLBundleName": @"",
		@"vendor-id": pciU32(0x1002),
		@"device-id": pciU32(0x15e7),
		@"class-code": pciU32(0x030000),
		@"revision-id": pciU32(0),
		@"subsystem-vendor-id": pciU32(0x1002),
		@"subsystem-id": pciU32(0),
	};
	fprintf(stderr, "iokit_pci_id_cfdata_v1 IOGraphicsAccelerator2 vendor-id=OSData\n");
	fflush(stderr);
	publishNamedService(targetServiceRegistry, "IOGraphicsAccelerator2", parent, graphicsAccelProps);

	// Empty live nub. Chromium matches AppleSMC; a null port is not fatal
	// but a live one lets matching complete the same way as IOPMPowerSource.
	publishNamedService(targetServiceRegistry, "AppleSMC", parent, nil);
}
