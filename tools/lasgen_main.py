"""Entry point for the bundled helper; legacy gen.py arguments stay unchanged."""
import sys

if len(sys.argv) > 1 and sys.argv[1] == 'extract':
    from game_extract import main
    sys.exit(main(sys.argv[2:]))
else:
    from gen import main
    main()
