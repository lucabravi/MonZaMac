"""Entry point for the bundled helper; legacy gen.py arguments stay unchanged."""
import sys

if len(sys.argv) > 1 and sys.argv[1] == 'extract':
    from game_extract import main
    sys.exit(main(sys.argv[2:]))
elif len(sys.argv) > 1 and sys.argv[1] == 'shader-catalog':
    from za.shader_catalog import main
    sys.exit(main(sys.argv[2:]))
elif len(sys.argv) > 2 and sys.argv[1] == 'online':  # tools/lumiose/<tool>.py (commands.py): prepare, activate, ...
    import runpy
    tool = sys.argv[2]
    if tool not in ('setup_online', 'prepare', 'prepare_game', 'activate', 'fetch'):
        sys.exit(f'lasgen online: unknown tool {tool}')
    sys.argv = [tool, *sys.argv[3:]]
    runpy.run_module(tool, run_name='__main__', alter_sys=True)
else:
    from gen import main
    main()
