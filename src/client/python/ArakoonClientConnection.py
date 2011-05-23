"""
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2010 Incubaid BVBA

Licensees holding a valid Incubaid license may use this file in
accordance with Incubaid's Arakoon commercial license agreement. For
more information on how to enter into this agreement, please contact
Incubaid (contact details can be found on www.arakoon.org/licensing).

Alternatively, this file may be redistributed and/or modified under
the terms of the GNU Affero General Public License version 3, as
published by the Free Software Foundation. Under this license, this
file is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.

See the GNU Affero General Public License for more details.
You should have received a copy of the
GNU Affero General Public License along with this program (file "COPYING").
If not, see <http://www.gnu.org/licenses/>.
"""

import socket
from ArakoonProtocol import *
from ArakoonExceptions import *

class ArakoonClientConnection :

    def __init__ (self, nodeLocation, clusterId):
        self._clusterId = clusterId
        self._nodeLocation = nodeLocation
        self._connected = False
        self._socket = None
        self._reconnect()

    def _reconnect(self):
        self.close()
        try :
            self._socket = socket.create_connection( self._nodeLocation ,
                    ArakoonClientConfig.getConnectionTimeout() )
            sendPrologue(self._socket, self._clusterId)
            self._connected = True
        except Exception, ex :
            ArakoonClientLogger.logWarning( "Unable to connect to %s:%s (%s: '%s')" ,
                                            self._nodeLocation[0],
                                            self._nodeLocation[1],
                                            ex.__class__.__name__,
                                            ex  )

    def send(self, msg):
        
        if not self._connected :
            self._reconnect()
            if not self._connected :
                raise ArakoonNotConnected( self._nodeLocation )
        try:
            self._socket.sendall( msg )
        except Exception, ex:
            self.close()
            ArakoonClientLogger.logWarning( "Error while sending data to (%s,%s) => %s: '%s'" , 
                self._nodeLocation[0], self._nodeLocation[1], ex.__class__.__name__, ex  ) 
            raise ArakoonSockSendError ()

    def close(self):
        if self._connected and self._socket is not None :
            try:
                self._socket.close()
            except Exception, ex:
                ArakoonClientLogger.logError( "Error while closing socket to %s:%s (%s: '%s')" , 
                    self._nodeLocation[0], self._nodeLocation[1], ex.__class__.__name__, ex  )

            self._connected = False

    def decodeStringResult(self) :
        return ArakoonProtocol.decodeStringResult ( self )

    def decodeBoolResult(self) :
        return ArakoonProtocol.decodeBoolResult ( self )

    def decodeVoidResult(self) :
        ArakoonProtocol.decodeVoidResult ( self )

    def decodeStringOptionResult (self):
        return ArakoonProtocol.decodeStringOptionResult ( self )

    def decodeStringListResult(self) :
        return ArakoonProtocol.decodeStringListResult ( self )

    def decodeStringPairListResult(self) :
        return ArakoonProtocol.decodeStringPairListResult ( self )

    def decodeStatistics(self):
        return ArakoonProtocol.decodeStatistics(self)
