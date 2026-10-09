from hello_common.app import run


def main() -> None:
    from .main import build_app

    run(build_app())


if __name__ == "__main__":
    main()
