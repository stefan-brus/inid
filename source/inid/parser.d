/**
 * Copyright 2016 Stefan Brus
 *
 * inid config parser module
 *
 * Usage example:
 *
 * enum CONFIG_STR = `[Category]
 * num_val = 42
 * str_val = foo`;
 *
 * struct Config
 * {
 *     struct Category
 *     {
 *         uint num_val;
 *         string str_val;
 *     }
 *
 *     Category category;
 * }
 *
 * auto config = ConfigParser!Config(CONFIG_STR);
 *
 * assert(config.category.num_val == 42);
 * assert(config.category.str_val == "foo");
 */

module inid.parser;

/**
 * Helper function to parse a config.ini file
 *
 * Template_params:
 *      Config = The type of the config struct
 *
 * Params:
 *      path = The path to the config.ini file
 *
 * Returns:
 *      The config parser
 *
 * Throws:
 *      ConfigException on parse error
 */

ConfigParser!Config parseConfigFile ( Config ) ( string path )
{
    import std.file;

    return ConfigParser!Config(readText(path));
}

/**
 * Exception thrown during config parser errors
 */

class ConfigException : Exception
{
    /**
     * Constructor
     *
     * Params:
     *      msg = The message
     *      file = The file
     *      line = The line
     */

    this ( string msg, string file = __FILE__, uint line = __LINE__ )
    {
        super(msg, file, line);
    }
}

/**
 * Config parser struct
 *
 * Template_params:
 *      Config = The type of the struct to try to parse
 */

struct ConfigParser ( Config )
{
    static assert(is(Config == struct), "ConfigParser type argument must be a struct");

    /**
     * The config struct
     */

    Config config;

    alias config this;

    /**
     * Constructor
     *
     * Params:
     *      str = The config string
     */

    this ( string str )
    {
        this.parse(str);
    }

    /**
     * Parse a config string
     *
     * Params:
     *      str = The config string
     *
     * Throws:
     *      ConfigException on parse error
     */

    void parse ( string str )
    {
        import std.algorithm;
        import std.array;
        import std.exception;
        import std.format;
        import std.string;
        import std.traits;

        // Reset the config struct
        this.config = Config.init;

        // Field name tuple of the config struct
        alias CategoryNames = FieldNameTuple!Config;

        // Split the string into lines, strip whitespace, remove empty strings, remove comments
        auto stripped_lines = str.split('\n').map!(strip).array().remove!(a => a.length == 0).remove!(a => a[0] == ';');

        // The current [CATEGORY] index
        size_t cat_idx;

        foreach ( idx, ref field; this.config.tupleof )
        {
            static assert(is(typeof(field) == struct), "ConfigParser fields must be structs");

            // Enforce that we have not reached the end while there are still categories to parse
            enforce!ConfigException(cat_idx < stripped_lines.length, format("Expected category %s", CategoryNames[idx].toUpper()));

            // Attempt to parse a [CATEGORY] name
            auto cat_line = stripped_lines[cat_idx];

            // Enforce that the current line is a category
            assert(cat_line.length > 0);
            enforce!ConfigException(cat_line[0] == '[' && cat_line[$ - 1] == ']', format("Expected a category, got: %s", cat_line));

            // Strip the whitespace from inside the brackets
            assert(cat_line.length > 1);
            auto cat_name = cat_line[1 .. $ - 1].strip();

            // Enforce that the category name is the same as the struct type name
            enforce!ConfigException(cat_name.toLower() == typeof(field).stringof.toLower(), format("Expected category %s", typeof(field).stringof));

            // Find the index of the next category
            size_t next_cat_idx;
            for ( auto i = cat_idx + 1; i < stripped_lines.length; i++ )
            {
                assert(stripped_lines[i].length > 0);

                if ( stripped_lines[i][0] == '[' )
                {
                    next_cat_idx = i;
                    break;
                }
            }

            // If no category was found, set the next index to the end of the config string
            if ( next_cat_idx == 0 )
            {
                next_cat_idx = stripped_lines.length;
            }

            // Enforce that there is at least one line between this category and the next
            enforce!ConfigException(next_cat_idx > cat_idx + 1, format("Category %s is empty", cat_name.toUpper()));

            // Parse the category into a struct
            field = this.parseStruct!(typeof(field))(stripped_lines[cat_idx + 1 .. next_cat_idx]);

            // Update the category index
            cat_idx = next_cat_idx;
        }
    }

    alias opCall = parse;

    /**
     * Static parse function
     *
     * Creates a config parser, attempts to parse, and returns the result
     *
     * Params:
     *      str = The config string
     *
     * Returns:
     *      The config struct
     *
     * Throws:
     *      ConfigException on parse error
     */

    static Config parseResult ( string str )
    {
        auto parser = ConfigParser(str);
        return parser;
    }

    static alias opCall = parseResult;

    /**
     * Helper function to parse a struct from a list of lines
     *
     * Template_params:
     *      T = The struct type
     *
     * Params:
     *      lines = The lines
     *
     * Returns:
     *      The parsed struct
     *
     * Throws:
     *      ConfigException on parse error
     */

    private T parseStruct ( T ) ( string[] lines )
    {
        import std.array;
        import std.conv;
        import std.exception;
        import std.format;
        import std.string;
        import std.traits;

        // Field name tuple of the struct to parse
        alias FieldNames = FieldNameTuple!T;

        // The category name
        auto category = T.stringof.toUpper();

        // Enforce that the category has the expected number of lines
        enforce!ConfigException(T.tupleof.length == lines.length, format("[%s] Expected %d fields", category, T.tupleof.length));

        // Build an associative array of the config key value pairs
        string[string] field_map;

        // Parse the lines as key value pairs of the "key = value" format
        foreach ( line; lines )
        {
            auto kv = line.split('=');

            // Enforce that the line contains one '='
            enforce!ConfigException(kv.length == 2, format("[%s] Fields must be \"key = value\" pairs", category));

            auto key = kv[0].strip();
            auto val = kv[1].strip();

            // Enforce that the entry has both a key and a value
            enforce!ConfigException(key.length > 0 && val.length > 0, format("[%s] Fields must be \"key = value\" pairs", category));

            field_map[key.toLower()] = val;
        }

        // Build the result struct based on the associative array
        T result;
        foreach ( i, ref field; result.tupleof )
        {
            auto field_name = FieldNames[i].toLower();

            // Enforce that the field is configured
            enforce!ConfigException(field_name in field_map, format("[%s] Expected field: %s", category, field_name));

            // Attempt to convert the value to the appropriate type
            try
            {
                field = to!(typeof(field))(field_map[field_name]);
            }
            catch ( Exception e )
            {
                throw new ConfigException(format("[%s] Field %s must be of type %s", category, field_name, typeof(field).stringof));
            }
        }

        return result;
    }
}

unittest
{
    struct Config
    {
        struct Entry
        {
            ulong key;
            string value;
        }

        Entry entry;
    }

    enum CONFIG_STR = `
; The first test config
  [ ENTRY ]
  value = the value
  key = 1234567891011
`;

    auto parser = ConfigParser!Config(CONFIG_STR);
    assert(parser.entry.key == 1234567891011);
    assert(parser.entry.value == "the value");
}

unittest
{
    struct Config
    {
        struct Server
        {
            string address;
            ushort port;
        }

        Server server;

        struct Route
        {
            string url;
            string path;
            uint response_code;
        }

        Route route;
    }

    enum CONFIG_STR = `

;
; Server configuration
;

[ Server ]

  ADDRESS       = 127.0.0.1

  PORT          = 32768

;
; Index route
;

[ Route ]

  URL           = /index.html

  PATH          = public/index.html

  RESPONSE_CODE = 200

`;

    auto parser = ConfigParser!Config(CONFIG_STR);
    assert(parser.server.address == "127.0.0.1");
    assert(parser.server.port == 32768);
    assert(parser.route.url == "/index.html");
    assert(parser.route.path == "public/index.html");
    assert(parser.route.response_code == 200);
}

unittest
{
    struct Config
    {
        struct MixedValues
        {
            uint integer;
            double decimal;
            bool flag;
            string text;
        }

        MixedValues mixed_values;
    }

    enum CONFIG_STR = `
[MixedValues]
integer = 42
decimal = 66.6
flag = true
text = This is some text
`;

    auto parser = ConfigParser!Config(CONFIG_STR);
    assert(parser.mixed_values.integer == 42);
    assert(parser.mixed_values.decimal == 66.6);
    assert(parser.mixed_values.flag == true);
    assert(parser.mixed_values.text == "This is some text");
}
