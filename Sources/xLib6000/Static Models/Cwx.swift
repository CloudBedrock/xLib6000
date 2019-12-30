//
//  Cwx.swift
//  xLib6000
//
//  Created by Douglas Adams on 6/30/15.
//  Copyright © 2015 Douglas Adams. All rights reserved.
//

import Foundation

/// Cwx Class implementation
///
///      creates a Cwx instance to be used by a Client to support the
///      rendering of a Cwx. Cwx objects are added, removed and updated
///      by the incoming TCP messages.
///
public final class Cwx                      : NSObject, StaticModel {

  // ----------------------------------------------------------------------------
  // MARK: - Public properties
  
  public var messageQueuedEventHandler      : ((_ sequence: Int, _ bufferIndex: Int) -> Void)?
  public var charSentEventHandler           : ((_ index: Int) -> Void)?
  public var eraseSentEventHandler          : ((_ start: Int, _ stop: Int) -> Void)?
  
  // ------------------------------------------------------------------------------
  // MARK: - Internal properties
  
  internal var macros                       : [String]
  internal let kMaxNumberOfMacros           = 12                            
    
  @BarrierClamped(0, Api.objectQ, range: 0...2_000) var _breakInDelay
  @BarrierClamped(0, Api.objectQ, range: 5...100)   var _wpm

  @Barrier(false, Api.objectQ) var _qskEnabled

  // ------------------------------------------------------------------------------
  // MARK: - Private properties
  
  private let _log                          = Log.sharedInstance
  private let _radio                        : Radio

  // ------------------------------------------------------------------------------
  // MARK: - Initialization
  
  /// Initialize Cwx
  ///
  /// - Parameters:
  ///   - radio:        the Radio instance
  ///
  init(radio: Radio) {
    
    _radio = radio
    macros = [String](repeating: "", count: kMaxNumberOfMacros)
    
    super.init()
  }
  
  // ------------------------------------------------------------------------------
  // MARK: - Public instance methods
  
  /// Get the specified Cwx Macro
  ///
  ///     NOTE:
  ///         Macros are numbered 0..<kMaxNumberOfMacros internally
  ///         Macros are numbered 1...kMaxNumberOfMacros in commands
  ///
  /// - Parameters:
  ///   - index:              the index of the macro
  ///   - macro:              on return, contains the text of the macro
  /// - Returns:              true if found, false otherwise
  ///
  public func getMacro(index: Int, macro: inout String) -> Bool {
    
    if index < 0 || index > kMaxNumberOfMacros - 1 { return false }
    
    macro = macros[index]
    
    return true
  }
  
  // ------------------------------------------------------------------------------
  // MARK: - Instance methods
  
  /// Process a Cwx command reply
  ///
  /// - Parameters:
  ///   - command:        the original command
  ///   - seqNum:         the Sequence Number of the original command
  ///   - responseValue:  the response value
  ///   - reply:          the reply
  ///
  func replyHandler(_ command: String, seqNum: UInt, responseValue: String, reply: String) {
    
    // if a block was specified for the "cwx send" command the response is "charPos,block"
    // if no block was given the response is "charPos"
    let values = reply.components(separatedBy: ",")
    
    let components = values.count
    
    // if zero or anything greater than 2 it's an error, log it and ignore the Reply
    guard components == 1 || components == 2 else {
      _log.msg("\(command), Invalid Cwx reply", level: .warning, function: #function, file: #file, line: #line)
      return
    }
    // get the character position
    let charPos = Int(values[0])
    
    // if not an integer, log it and ignore the Reply
    guard charPos != nil else {
      _log.msg("\(command), Invalid Cwx character position", level: .warning, function: #function, file: #file, line: #line)
      return
    }

    if components == 1 {
      
      // 1 component - no block number
      
      // inform the Event Handler (if any), use 0 as a block identifier
      messageQueuedEventHandler?(charPos!, 0)
      
    } else {
      
      // 2 components - get the block number
      let block = Int(values[1])
      
      // not an integer, log it and ignore the Reply
      guard block != nil else {
        
        _log.msg("\(command), Invalid Cwx block", level: .warning, function: #function, file: #file, line: #line)
        return
      }
      // inform the Event Handler (if any)
      messageQueuedEventHandler?(charPos!, block!)
    }
  }
  
  // ------------------------------------------------------------------------------
  // MARK: - Protocol instance methods

  /// Parse Cwx key/value pairs, called by Radio
  ///
  ///   PropertiesParser protocol method, executes on the parseQ
  ///
  /// - Parameter properties:       a KeyValuesArray
  ///
  func parseProperties(_ properties: KeyValuesArray)  {
    
    // function to change value and signal KVO
//    func update<T>(_ property: UnsafeMutablePointer<T>, to value: T, signal keyPath: KeyPath<Cwx, T>) {
//      willChangeValue(for: keyPath)
//      property.pointee = value
//      didChangeValue(for: keyPath)
//    }

    // process each key/value pair, <key=value>
    for property in properties {
      
      // is it a Macro?
      if property.key.hasPrefix("macro") && property.key.lengthOfBytes(using: String.Encoding.ascii) > 5 {
        
        // YES, get the index
        let oIndex = property.key.firstIndex(of: "o")!
        let numberIndex = property.key.index(after: oIndex)
        let index = Int( property.key[numberIndex...] ) ?? 0
        
        // ignore invalid indexes
        if index < 1 || index > kMaxNumberOfMacros { continue }
        
        // update the macro after "unFixing" the string
        macros[index - 1] = property.value.unfix()
        
      } else {
        
        // Check for Unknown Keys
        guard let token = Token(rawValue: property.key) else {
          // log it and ignore the Key
          _log.msg("Unknown Cwx token: \(property.key) = \(property.value)", level: .warning, function: #function, file: #file, line: #line)
          continue
        }
        // Known tokens, in alphabetical order
        switch token {
          
        case .breakInDelay:
          update(self, &_breakInDelay, to: property.value.iValue, signal: \.breakInDelay)

        case .erase:
          let values = property.value.components(separatedBy: ",")
          if values.count != 2 { break }
          let start = Int(values[0])
          let stop = Int(values[1])
          if let start = start, let stop = stop {
            // inform the Event Handler (if any)
            eraseSentEventHandler?(start, stop)
          }
          
        case .qskEnabled:
          update(self, &_qskEnabled, to: property.value.bValue, signal: \.qskEnabled)

        case .sent:
          // inform the Event Handler (if any)
          charSentEventHandler?(property.value.iValue)
          
        case .wpm:
          update(self, &_wpm, to: property.value.iValue, signal: \.wpm)
        }
      }
    }
  }
}

extension Cwx {
    
    // ----------------------------------------------------------------------------
    // Public properties (KVO compliant) that send Commands
    
    @objc dynamic public var breakInDelay: Int {
      get { return _breakInDelay }
      set { if _breakInDelay != newValue { let value = newValue ;  _breakInDelay = value ; cwxCmd( "delay", value) } } }
    
    @objc dynamic public var qskEnabled: Bool {
      get { return _qskEnabled }
      set { if _qskEnabled != newValue { _qskEnabled = newValue ; cwxCmd( .qskEnabled, newValue.as1or0) } } }
    
    @objc dynamic public var wpm: Int {
      get { return _wpm }
      set { if _wpm != newValue { let value = newValue ; if _wpm != value  { _wpm = value ; cwxCmd( .wpm, value) } } } }
  
  // ------------------------------------------------------------------------------
  // Instance methods that send Commands

  /// Clear the character buffer
  ///
  public func clearBuffer() {
    _radio.sendCommand("cwx " + "clear")
  }
  /// Erase "n" characters
  ///
  /// - Parameter numberOfChars:  number of characters to erase
  ///
  public func erase(numberOfChars: Int) {
    _radio.sendCommand("cwx " + "erase \(numberOfChars)")
  }
  /// Erase "n" characters
  ///
  /// - Parameters:
  ///   - numberOfChars:          number of characters to erase
  ///   - radioIndex:             ???
  ///
  public func erase(numberOfChars: Int, radioIndex: Int) {
    _radio.sendCommand("cwx " + "erase \(numberOfChars)" + " \(radioIndex)")
  }
  /// Insert a string of Cw, optionally with a block
  ///
  /// - Parameters:
  ///   - string:                 the text to insert
  ///   - index:                  the index at which to insert the messagek
  ///   - block:                  an optional block
  ///
  public func insert(_ string: String, index: Int, block: Int? = nil) {
    
    // replace spaces with 0x7f
    let msg = String(string.map { $0 == " " ? "\u{7f}" : $0 })
    
    if let block = block {
      
      _radio.sendCommand("cwx insert " + "\(index) \"" + msg + "\" \(block)", replyTo: replyHandler)
      
    } else {
      
      _radio.sendCommand("cwx insert " + "\(index) \"" + msg + "\"", replyTo: replyHandler)
    }
  }
  /// Save the specified Cwx Macro and tell the Radio (hardware)
  ///
  ///     NOTE:
  ///         Macros are numbered 0..<kMaxNumberOfMacros internally
  ///         Macros are numbered 1...kMaxNumberOfMacros in commands
  ///
  /// - Parameters:
  ///   - index:              the index of the macro
  ///   - msg:                the text of the macro
  /// - Returns:              true if found, false otherwise
  ///
  public func saveMacro(index: Int, msg: String) -> Bool {
    
    if index < 0 || index > kMaxNumberOfMacros - 1 { return false }
    
    macros[index] = msg
    
    _radio.sendCommand("cwx macro " + "save \(index+1)" + " \"" + msg + "\"")
    
    return true
  }
  /// Send a string of Cw, optionally with a block
  ///
  /// - Parameters:
  ///   - string:         the text to send
  ///   - block:          an optional block
  ///
  public func send(_ string: String, block: Int? = nil) {
    
    // replace spaces with 0x7f
    let msg = String(string.map { $0 == " " ? "\u{7f}" : $0 })
    
    if let block = block {
      
      _radio.sendCommand("cwx send " + "\"" + msg + "\" \(block)", replyTo: replyHandler)
      
    } else {
      
      _radio.sendCommand("cwx send " + "\"" + msg + "\"", replyTo: replyHandler)
    }
  }
  /// Send the specified Cwx Macro
  ///
  /// - Parameters:
  ///   - index: the index of the macro
  ///   - block: an optional block ( > 0)
  ///
  public func sendMacro(index: Int, block: Int? = nil) {
    
    if index < 0 || index > kMaxNumberOfMacros { return }
    
    if let block = block {
      
      _radio.sendCommand("cwx macro " + "send \(index) \(block)", replyTo: replyHandler)
      
    } else {
      
      _radio.sendCommand("cwx macro " + "send \(index)", replyTo: replyHandler)
    }
  }

  // ----------------------------------------------------------------------------
  // Private command helper methods

  /// Set a Cwx property on the Radio
  ///
  /// - Parameters:
  ///   - token:      the parse token
  ///   - value:      the new value
  ///
  private func cwxCmd(_ token: Token, _ value: Any) {
    
    _radio.sendCommand("cwx " + token.rawValue + " \(value)")
  }
  /// Set a Cwx property on the Radio
  ///
  /// - Parameters:
  ///   - token:      a String
  ///   - value:      the new value
  ///
  private func cwxCmd(_ token: String, _ value: Any) {
    // NOTE: commands use this format when the Token received does not match the Token sent
    //      e.g. see EqualizerCommands.swift where "63hz" is received vs "63Hz" must be sent
    _radio.sendCommand("cwx " + token + " \(value)")
  }
  // ----------------------------------------------------------------------------
  // Tokens
  
  /// Properties
  ///
  internal enum Token : String {
    case breakInDelay   = "break_in_delay"            // "delay"
    case qskEnabled     = "qsk_enabled"
    case erase
    case sent
    case wpm            = "wpm"
  }
  
}
