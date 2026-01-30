pub const ParseError = error {
    UnexpectedToken,
    ExpressionExpected,
    FloatError,
    OutOfMemory
};

pub const EvalError = error {
    InvalidType,
    TypeMismatch,
    InvalidExpression,
    DivisionByZero,
    UndefinedVariable
};

