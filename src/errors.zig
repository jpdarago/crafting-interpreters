pub const ParseError = error {
    UnexpectedToken,
    ExpressionExpected,
    FloatError,
    OutOfMemory,
    MaximumArgumentsExceeded
};

pub const EvalError = error {
    InvalidType,
    TypeMismatch,
    InvalidExpression,
    DivisionByZero,
    UndefinedVariable,
    InternalFailure,
    InvalidArguments
};

