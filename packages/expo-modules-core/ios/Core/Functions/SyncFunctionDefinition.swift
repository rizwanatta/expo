// Copyright 2022-present 650 Industries. All rights reserved.

/**
 Type-erased protocol for synchronous functions.
 */
internal protocol AnySyncFunctionDefinition: AnyFunctionDefinition {
  /**
   Calls the function synchronously with given arguments.
   - Parameters:
     - owner: An object that calls this function. If the `takesOwner` property is true
       and type of the first argument matches the owner type, it's being passed as the argument.
     - args: An array of arguments to pass to the function. The arguments must be of the same type as in the underlying closure.
     - appContext: An app context where the function is executed.
   - Returns: A value returned by the called function when succeeded or an error when it failed.
   */
  func call(by owner: AnyObject?, withArguments args: [Any], appContext: AppContext) throws -> Any
}

/**
 Represents a function that can only be called synchronously.
 */
public final class SyncFunctionDefinition<Args, FirstArgType, ReturnType>: AnySyncFunctionDefinition {
  typealias ClosureType = (Args) throws -> ReturnType

  /**
   The underlying closure to run when the function is called.
   */
  let body: ClosureType

  init(
    _ name: String,
    firstArgType: FirstArgType.Type,
    dynamicArgumentTypes: [AnyDynamicType],
    _ body: @escaping ClosureType
  ) {
    self.name = name
    self.dynamicArgumentTypes = dynamicArgumentTypes
    self.body = body
  }

  // MARK: - AnyFunction

  let name: String

  let dynamicArgumentTypes: [AnyDynamicType]

  var argumentsCount: Int {
    return dynamicArgumentTypes.count - (takesOwner ? 1 : 0)
  }

  var takesOwner: Bool = false

  func call(by owner: AnyObject?, withArguments args: [Any], appContext: AppContext, callback: @escaping (FunctionCallResult) -> ()) {
    do {
      let result = try call(by: owner, withArguments: args, appContext: appContext)
      callback(.success(Conversions.convertFunctionResult(result)))
    } catch let error as Exception {
      callback(.failure(error))
    } catch {
      callback(.failure(UnexpectedException(error)))
    }
  }

  // MARK: - AnySyncFunctionDefinition

  func call(by owner: AnyObject?, withArguments args: [Any], appContext: AppContext) throws -> Any {
    do {
      try validateArgumentsNumber(function: self, received: args.count)

      var arguments = concat(
        arguments: args,
        withOwner: owner,
        withPromise: nil,
        forFunction: self,
        appContext: appContext
      )

      // Convert JS values to non-JS native types.
      arguments = try cast(jsValues: arguments, forFunction: self, appContext: appContext)

      // Convert arguments to the types desired by the function.
      arguments = try cast(arguments: arguments, forFunction: self, appContext: appContext)

      guard let argumentsTuple = try Conversions.toTuple(arguments) as? Args else {
        throw ArgumentConversionException()
      }

      return try body(argumentsTuple)
    } catch let error as Exception {
      throw FunctionCallException(name).causedBy(error)
    } catch {
      throw UnexpectedException(error)
    }
  }

  // MARK: - JavaScriptObjectBuilder

  func build(appContext: AppContext) throws -> JavaScriptObject {
    // We intentionally capture a strong reference to `self`, otherwise the "detached" objects would
    // immediately lose the reference to the definition and thus the underlying native function.
    // It may potentially cause memory leaks, but at the time of writing this comment,
    // the native definition instance deallocates correctly when the JS VM triggers the garbage collector.
    return try appContext.runtime.createSyncFunction(name, argsCount: argumentsCount) { [weak appContext, self] this, args in
      guard let appContext else {
        throw Exceptions.AppContextLost()
      }
      let result = try self.call(by: this, withArguments: args, appContext: appContext)
      return Conversions.convertFunctionResult(result, appContext: appContext, dynamicType: ~ReturnType.self)
    }
  }
}
