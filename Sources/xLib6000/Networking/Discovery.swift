//
//  Discovery.swift
//
//  Created by Douglas Adams on 5/13/15
//  Copyright © 2018 Douglas Adams & Mario Illgen. All rights reserved.
//

import Foundation
import CocoaAsyncSocket

/// Discovery implementation
///
///      listens for the udp broadcasts announcing the presence of a Flex-6000
///      Radio, reports changes to the list of available radios
///
public final class Discovery                : NSObject, GCDAsyncUdpSocketDelegate {
  
  // ----------------------------------------------------------------------------
  // MARK: - Static properties

  // GCD Queues
  static let udpQ                           = DispatchQueue(label: "Discovery" + ".udpQ")
  static let timerQ                         = DispatchQueue(label: "Discovery" + ".timerQ")

  // ----------------------------------------------------------------------------
  // MARK: - Public properties
  
  public var discoveredRadios: [DiscoveryPacket] {
    get { Api.objectQ.sync { _discoveredRadios } }
    set { Api.objectQ.sync(flags: .barrier) { _discoveredRadios = newValue }}}

  // ----------------------------------------------------------------------------
  // MARK: - Private properties

  private var _discoveredRadios             = [DiscoveryPacket]()
  private var _timeoutTimer                 : DispatchSourceTimer!
  private var _udpSocket                    : GCDAsyncUdpSocket?
  
  // ----------------------------------------------------------------------------
  // MARK: - Singleton
  
  /// Provide access to the API singleton
  ///
  public static var sharedInstance = Discovery()
  
  /// Initialize Discovery
  ///
  /// - Parameters:
  ///   - discoveryPort:        port number
  ///   - checkInterval:        how often to check
  ///   - notSeenInterval:      timeout interval
  ///
  private init(discoveryPort: UInt16 = 4992, checkInterval: TimeInterval = 1.0, notSeenInterval: TimeInterval = 3.0) {
    super.init()
    
    // create a Udp socket
    _udpSocket = GCDAsyncUdpSocket( delegate: self, delegateQueue: Discovery.udpQ )
    
    // if created
    if let sock = _udpSocket {
      
      // set socket options
      sock.setPreferIPv4()
      sock.setIPv6Enabled(false)
      
      // enable port reuse (allow multiple apps to use same port)
      do {
        try sock.enableReusePort(true)
        
      } catch let error as NSError {
        fatalError("Port reuse not enabled: \(error.localizedDescription)")
      }
      
      // bind the socket to the Flex Discovery Port
      do {
        try sock.bind(toPort: discoveryPort)
      }
      catch let error as NSError {
        fatalError("Bind to port error: \(error.localizedDescription)")
      }
      
      do {
        
        // attempt to start receiving
        try sock.beginReceiving()
        
        // create the timer's dispatch source
        _timeoutTimer = DispatchSource.makeTimerSource(flags: [.strict], queue: Discovery.timerQ)
        
        // Set timer with 100 millisecond leeway
        _timeoutTimer.schedule(deadline: DispatchTime.now(), repeating: checkInterval, leeway: .milliseconds(100))      // Every second +/- 10%
        
        // set the event handler
        _timeoutTimer.setEventHandler { [ unowned self] in
          
          var deleteList = [Int]()
          
          // check the timestamps of the Discovered radios
          for i in 0..<self.discoveredRadios.count {
            
            if !self.discoveredRadios[i].isWan {
              
              let interval = abs(self.discoveredRadios[i].lastSeen.timeIntervalSinceNow)
              
              // is it past expiration?
              if interval > notSeenInterval {                
                
//                Swift.print("Delete @ Index = \(i), interval = \(interval)")
                
                // YES, add to the delete list
                deleteList.append(i)
              }
            }
          }
          // are there any deletions?
          if deleteList.count > 0 {
            
            // YES, remove the Radio(s)
            for index in deleteList.reversed() {
              
              // remove a Radio
              self.discoveredRadios.remove(at: index)
            }
          }
          // update the last seen date in remaining discoveredRadios
          for i in 0..<self.discoveredRadios.count {
            self.discoveredRadios[i].lastSeen = Date()
          }
        }
        
      } catch let error as NSError {
        fatalError("Begin receiving error: \(error.localizedDescription)")
      }
      // start the timer
      _timeoutTimer.resume()
    }
  }
  
  deinit {
    _timeoutTimer?.cancel()
    
    _udpSocket?.close()
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Public methods
  
  /// Pause the collection of UDP broadcasts
  ///
  public func pause() {
  
    if let sock = _udpSocket {
      
      // pause receiving UDP broadcasts
      sock.pauseReceiving()
      
      // pause the timer
      _timeoutTimer.suspend()
    }
  }
  /// Resume the collection of UDP broadcasts
  ///
  public func resume() {
    
    if let sock = _udpSocket {
      
      // restart receiving UDP broadcasts
      try! sock.beginReceiving()
      
      // restart the timer
      _timeoutTimer.resume()
    }
  }
  /// force a Notification containing a list of current radios
  ///
  public func updateDiscoveredRadios() {
    
    // send the current list of radios to all observers
    NC.post(.discoveredRadios, object: self.discoveredRadios as Any?)
  }
  /// Process a DiscoveryPacket
  /// - Parameter newPacket: the packet
  ///
  public func processPacket(_ newPacket: DiscoveryPacket) {
    
    // parse the packet to populate its GuiClients
    parseGuiClientsFromDiscovery(newPacket)
    
    // is there a previous packet with the same serialNumber and isWan?
    if let radioIndex = findRadioPacket(with: newPacket) {

      // known radio
      scanGuiClients(newPacket, discoveredRadios[radioIndex])

    } else {
      // unknown radio, add it
      discoveredRadios.append(newPacket)

      for i in 0..<newPacket.guiClients.count {
        Log.sharedInstance.logMessage("\(newPacket.nickname), GuiClient added:   \(newPacket.guiClients[i].handle.hex), \(newPacket.guiClients[i].station), \(newPacket.guiClients[i].program)", .debug, #function, #file, #line)
        NC.post(.guiClientHasBeenAdded, object: newPacket.guiClients[i].station as Any?)
      }
      // log Radio addition
      Log.sharedInstance.logMessage("Radio added: \(newPacket.nickname), isWan = \(newPacket.isWan)", .debug, #function, #file, #line)
      
      // notify observers of Radio addition
      NC.post(.discoveredRadios, object: discoveredRadios as Any?)
    }
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Private methods
  
  /// Parse the csv fields in a Discovery packet
  /// - Parameter packet:       the packet to parse
  ///
  private func parseGuiClientsFromDiscovery(_ packet: DiscoveryPacket) {
    
    guard packet.guiClientPrograms != "" && packet.guiClientStations != "" && packet.guiClientHandles != "" else { return }
    
    let programs  = packet.guiClientPrograms.components(separatedBy: ",")
    let stations  = packet.guiClientStations.components(separatedBy: ",")
    let handles   = packet.guiClientHandles.components(separatedBy: ",")
    let hosts     = packet.guiClientHosts.components(separatedBy: ",")
    let ips       = packet.guiClientIps.components(separatedBy: ",")
    
    guard programs.count == stations.count && programs.count == handles.count && stations.count == handles.count && hosts.count == handles.count && ips.count == handles.count else { return }
    
    for i in 0..<handles.count {
      
      if let handle = handles[i].handle {
        
        packet.guiClients.append( GuiClient(handle: handle,
                                     program: programs[i],
                                     station: stations[i].replacingOccurrences(of: "\u{007f}", with: " "),
                                     host: hosts[i],
                                     ip: ips[i]))
      }
    }
    return
  }
  /// Process GuiClient data in Discovery packet
  /// - Parameters:
  ///   - newPacket:        a newly received packet
  ///   - oldPacket:        the previous packet, to be updated
  ///
  private func scanGuiClients(_ newPacket: DiscoveryPacket, _ oldPacket: DiscoveryPacket) {
    
    // for each old GuiClient
    for i in (0..<oldPacket.guiClients.count).reversed() {
      
      // is it in the new list (i.e. same handle)?
      if !newPacket.guiClients.contains(oldPacket.guiClients[i]) {
        
        // NO, remove it
        let handle = oldPacket.guiClients[i].handle
        let station = oldPacket.guiClients[i].station
        let program = oldPacket.guiClients[i].program
        oldPacket.guiClients.remove(at: i)
        
        Log.sharedInstance.logMessage("\(newPacket.nickname), GuiClient removed: \(handle.hex), \(station), \(program)", .debug, #function, #file, #line)
        NC.post(.guiClientHasBeenRemoved, object: station as Any?)
      }
    }
    // for each new GuiClient
    for i in 0..<newPacket.guiClients.count {
      
      // is it in the old list (i.e. same handle)?
      if !oldPacket.guiClients.contains(newPacket.guiClients[i]) {
        if newPacket.guiClients[i].station.trimmingCharacters(in: .whitespaces) != "" && newPacket.guiClients[i].program.trimmingCharacters(in: .whitespaces) != "" {
          // NO, add it
          oldPacket.guiClients.append(newPacket.guiClients[i])
          
          Log.sharedInstance.logMessage("\(newPacket.nickname), GuiClient added:   \(newPacket.guiClients[i].handle.hex), \(newPacket.guiClients[i].station), \(newPacket.guiClients[i].program)", .debug, #function, #file, #line)
          NC.post(.guiClientHasBeenAdded, object: newPacket.guiClients[i].station as Any?)
        }
      }
    }
    updateOldPacket(oldPacket, newPacket)
  }
  /// Update the existing packet with the changeable fields from the current packet
  /// - Parameters:
  ///   - oldPacket:        the existing packet
  ///   - newPacket:        the new packet
  ///
  private func updateOldPacket(_ oldPacket: DiscoveryPacket, _ newPacket: DiscoveryPacket) {

    oldPacket.status                = newPacket.status
    oldPacket.availableClients      = newPacket.availableClients
    oldPacket.availablePanadapters  = newPacket.availablePanadapters
    oldPacket.availableSlices       = newPacket.availableSlices
    oldPacket.inUseHost             = newPacket.inUseHost
    oldPacket.inUseIp               = newPacket.inUseIp
    oldPacket.isWan                 = newPacket.isWan
  }
  /// Find a radio's Discovery packet
  /// - Parameter serialNumber:     a radio serial number
  /// - Returns:                    the index of the radio in Discovered Radios
  ///
  private func findRadioPacket(with newPacket: DiscoveryPacket) -> Int? {
    
    // is the Radio already in the discoveredRadios array?
    for (i, existingPacket) in discoveredRadios.enumerated() {
      // by serialNumber & isWan (same radio can be visible both locally and via SmartLink)
      if existingPacket.serialNumber == newPacket.serialNumber && existingPacket.isWan == newPacket.isWan { return i }
    }
    return nil
  }

  // ----------------------------------------------------------------------------
  // MARK: - GCDAsyncUdp delegate method
    
  /// The Socket received data
  ///
  ///   GCDAsyncUdpSocket delegate method, executes on the udpReceiveQ
  ///
  /// - Parameters:
  ///   - sock:           the GCDAsyncUdpSocket
  ///   - data:           the Data received
  ///   - address:        the Address of the sender
  ///   - filterContext:  the FilterContext
  ///
  @objc public func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
    
    // VITA encoded Discovery packet?
    guard let vita = Vita.decodeFrom(data: data) else { return }
    
    // parse vita to obtain a DiscoveryPacket
    guard let newPacket = Vita.parseDiscovery(vita) else { return }
    
//    Swift.print("BEFORE Discovery packet processed, Count = \(discoveredRadios.count)")

    processPacket(newPacket)

//    Swift.print("AFTER Discovery packet processed, Count = \(discoveredRadios.count)")
  }
}
/// GuiClient Class implementation
///
///     A struct therefore a "value" type
///     Equatable by handle
///
public struct GuiClient       : Equatable {
  
  public var clientId         : String? = nil

  public var handle           : Handle
  public var program          : String
  public var station          : String
  public var host             : String = ""
  public var ip               : String = ""

  public var isAvailable      : Bool = false
  public var isLocalPtt       : Bool = false
  public var isThisClient     : Bool = false
  
  public static func ==(lhs: GuiClient, rhs: GuiClient) -> Bool {
    
    if lhs.handle   != rhs.handle   { return false }
    if lhs.program  != rhs.program  { return false }
    if lhs.station  != rhs.station  { return false }
    return true
  }
  
  public static func !=(lhs: GuiClient, rhs: GuiClient) -> Bool {
    return !(lhs == rhs)
  }
}

/// DiscoveryPacket class implementation
///
///     A class therefore a "reference" type
///     Equatable by serial number
///
public class DiscoveryPacket : Equatable {
  
  // ----------------------------------------------------------------------------
  // MARK: - Public properties
  
  public var lastSeen                       = Date()
  
  public var availableClients               = 0                   // newAPI, Local only
  public var availablePanadapters           = 0                   // newAPI, Local only
  public var availableSlices                = 0                   // newAPI, Local only
  public var callsign                       = ""
  public var discoveryVersion               = ""                  // Local only
  public var firmwareVersion                = ""
  public var fpcMac                         = ""                  // Local only
  public var guiClients                     = [GuiClient]()
  public var guiClientHandles               = ""                  // newAPI only
  public var guiClientPrograms              = ""                  // newAPI only
  public var guiClientStations              = ""                  // newAPI only
  public var guiClientHosts                 = ""                  // newAPI only
  public var guiClientIps                   = ""                  // newAPI only
  public var inUseHost                      = ""                  // deprecated -- 2 spellings
  public var inUseIp                        = ""                  // deprecated -- 2 spellings
  public var licensedClients                = 0                   // newAPI, Local only
  public var maxLicensedVersion             = ""
  public var maxPanadapters                 = 0                   // newAPI, Local only
  public var maxSlices                      = 0                   // newAPI, Local only
  public var model                          = ""
  public var nickname                       = ""                  // 2 spellings
  public var port                           = -1                  // Local only
  public var publicIp                       = ""                  // 2 spellings
  public var publicTlsPort                  = -1                  // SmartLink only
  public var publicUdpPort                  = -1                  // SmartLink only
  public var publicUpnpTlsPort              = -1                  // SmartLink only
  public var publicUpnpUdpPort              = -1                  // SmartLink only
  public var radioLicenseId                 = ""
  public var requiresAdditionalLicense      = false
  public var serialNumber                   = ""
  public var status                         = ""
  public var upnpSupported                  = false               // SmartLink only
  public var wanConnected                   = false               // Local only
  

  
  // FIXME: Not really part of the DiscoveryPacket
  public var isPortForwardOn                = false               // ????
  public var isWan                          = false
  public var localInterfaceIP               = ""                  // ????
  public var lowBandwidthConnect            = false               // ????
  public var negotiatedHolePunchPort        = -1                  // ????
  public var requiresHolePunch              = false               // ????
  public var wanHandle                      = ""               

  
  public var description : String {
    return """
    Radio Serial:\t\t\(serialNumber)
    Licensed Version:\t\(maxLicensedVersion)
    Radio ID:\t\t\t\(radioLicenseId)
    Radio IP:\t\t\t\(publicIp)
    Radio Firmware:\t\t\(firmwareVersion)
    
    Handles:\t\(guiClientHandles)
    Hosts:\t\(guiClientHosts)
    Ips:\t\t\(guiClientIps)
    Programs:\t\(guiClientPrograms)
    Stations:\t\(guiClientStations)
    """
  }
    
  // ----------------------------------------------------------------------------
  // MARK: - Static methods
  
  /// Returns a Boolean value indicating whether two DiscoveredRadio instances are equal.
  ///
  /// - Parameters:
  ///   - lhs:            the left value
  ///   - rhs:            the right value
  ///
  public static func ==(lhs: DiscoveryPacket, rhs: DiscoveryPacket) -> Bool {
    
    // same serial number
    return lhs.serialNumber == rhs.serialNumber && lhs.isWan == rhs.isWan
  }
}

