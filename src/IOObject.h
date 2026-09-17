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

#ifndef IOKITD_IOOBJECT_H
#define IOKITD_IOOBJECT_H
#include <unordered_map>
#include <mach/mach.h>
#include <memory>

class IOObject
{
public:
	IOObject();
	// attachToIokitSet=false: receive right stays private (IOUserNotification).
	// Do not put that port in g_iokitPortSet during an in-flight MIG reply.
	explicit IOObject(bool attachToIokitSet);
	virtual ~IOObject();

	virtual const char* className() const = 0;
	virtual bool conformsTo(const char* className);

	void retain();
	void release();
	void releaseLater();

	mach_port_t port() { return m_port; }

	// IOUserNotification is born off the set so COPY_SEND in the in-flight
	// MIG reply cannot land on the same set. Attach after that reply is sent.
	void schedulePortSetAttach();
	static void flushPortSetAttaches();

	// TODO: This should start adding a reference and all call sites should retain.
	// At the latest when we support objects that may go away (e.g. USB devices).
	static IOObject* lookup(mach_port_t port);
	static boolean_t deathNotify(mach_msg_header_t *request, mach_msg_header_t *reply);
private:
	void initPort(bool attachToIokitSet);
	void attachToIokitSetNow();
	mach_port_t m_port;
	bool m_inPortSet;
	static std::unordered_map<mach_port_t, IOObject*> m_objects;
};

#endif
