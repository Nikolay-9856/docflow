--
-- PostgreSQL database dump
--

\restrict QCznDrwEPQG3EPd3gixozYoAOEXO3PuviAQdF2eURkJkrghuByYAODOBplhv7Qz

-- Dumped from database version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: fn_doc_files_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_doc_files_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT COALESCE(MAX(version_no), 0) + 1 INTO NEW.version_no
      FROM doc_files WHERE doc_id = NEW.doc_id;
    RETURN NEW;
END;
$$;


--
-- Name: fn_documents_status_audit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_documents_status_audit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO doc_status_log (doc_id, old_status, new_status, changed_by)
        VALUES (NEW.doc_id, NULL, NEW.status, NEW.author_id);
    ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO doc_status_log (doc_id, old_status, new_status, changed_by)
        VALUES (NEW.doc_id, OLD.status, NEW.status,
                NULLIF(current_setting('app.user_id', TRUE), '')::INT);
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: fn_set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;


--
-- Name: sp_decide_route(integer, character varying, character varying, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_decide_route(IN p_route_id integer, IN p_decision character varying, IN p_comment character varying, IN p_user_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    r doc_routes%ROWTYPE;
    v_left INT;
BEGIN
    SELECT * INTO r FROM doc_routes WHERE route_id = p_route_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Этап маршрута % не найден', p_route_id USING ERRCODE = 'P0002';
    ELSIF r.decision <> 'Ожидает' THEN
        RAISE EXCEPTION 'По этапу % решение уже принято: %', p_route_id, r.decision USING ERRCODE = 'P0001';
    ELSIF r.executor_id <> p_user_id THEN
        RAISE EXCEPTION 'Пользователь % не является исполнителем этапа', p_user_id USING ERRCODE = '42501';
    ELSIF p_decision NOT IN ('Согласовано', 'Отклонено') THEN
        RAISE EXCEPTION 'Недопустимое решение: %', p_decision USING ERRCODE = '22023';
    ELSIF p_decision = 'Отклонено' AND COALESCE(trim(p_comment), '') = '' THEN
        RAISE EXCEPTION 'При отклонении комментарий обязателен' USING ERRCODE = '22023';
    END IF;

    UPDATE doc_routes
       SET decision = p_decision, comment = p_comment, decided_at = now()
     WHERE route_id = p_route_id;

    PERFORM set_config('app.user_id', p_user_id::TEXT, TRUE);

    IF p_decision = 'Отклонено' THEN
        UPDATE documents SET status = 'На доработке' WHERE doc_id = r.doc_id;
    ELSE
        SELECT COUNT(*) INTO v_left FROM doc_routes
         WHERE doc_id = r.doc_id AND decision = 'Ожидает';
        IF v_left = 0 THEN
            UPDATE documents SET status = 'Согласован' WHERE doc_id = r.doc_id;
        END IF;
    END IF;
END;
$$;


--
-- Name: sp_register_document(character varying, smallint, integer, integer, date, integer, character varying); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_register_document(IN p_title character varying, IN p_type_id smallint, IN p_author_id integer, IN p_cp_id integer, IN p_due_date date, INOUT p_doc_id integer DEFAULT NULL::integer, INOUT p_reg_number character varying DEFAULT NULL::character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_prefix VARCHAR(5);
    v_dept   INT;
    v_seq    INT;
BEGIN
    SELECT reg_prefix INTO v_prefix FROM doc_types WHERE type_id = p_type_id;
    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'Вид документа % не найден', p_type_id USING ERRCODE = 'P0002';
    END IF;

    SELECT dept_id INTO v_dept FROM users WHERE user_id = p_author_id AND is_active;
    IF v_dept IS NULL THEN
        RAISE EXCEPTION 'Автор % не найден или заблокирован', p_author_id USING ERRCODE = 'P0002';
    END IF;

    -- сквозная нумерация в пределах вида документа и года
    PERFORM pg_advisory_xact_lock(p_type_id);
    SELECT COALESCE(MAX(split_part(reg_number, '-', 3)::INT), 0) + 1
      INTO v_seq
      FROM documents
     WHERE type_id = p_type_id
       AND split_part(reg_number, '-', 2) = to_char(current_date, 'YYYY');

    p_reg_number := v_prefix || '-' || to_char(current_date, 'YYYY') || '-' || lpad(v_seq::TEXT, 4, '0');

    INSERT INTO documents (reg_number, title, type_id, author_id, dept_id, cp_id, due_date)
    VALUES (p_reg_number, p_title, p_type_id, p_author_id, v_dept, p_cp_id, p_due_date)
    RETURNING doc_id INTO p_doc_id;
END;
$$;


--
-- Name: sp_register_user(character varying, character varying, character varying, character varying, integer, character varying, character, character, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_register_user(IN p_login character varying, IN p_full_name character varying, IN p_email character varying, IN p_position character varying, IN p_dept_id integer, IN p_role_code character varying, IN p_hash character, IN p_salt character, INOUT p_user_id integer DEFAULT NULL::integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_role SMALLINT;
BEGIN
    IF EXISTS (SELECT 1 FROM users WHERE lower(login) = lower(p_login)) THEN
        RAISE EXCEPTION 'Логин «%» уже занят', p_login USING ERRCODE = '23505';
    END IF;
    SELECT role_id INTO v_role FROM roles WHERE role_code = p_role_code;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'Роль % не существует', p_role_code USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO users (login, full_name, email, position, dept_id, role_id, password_hash, password_salt)
    VALUES (lower(p_login), p_full_name, lower(p_email), p_position, p_dept_id, v_role, p_hash, p_salt)
    RETURNING user_id INTO p_user_id;
END;
$$;


--
-- Name: sp_send_for_approval(integer, integer, character varying, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_send_for_approval(IN p_doc_id integer, IN p_executor_id integer, IN p_action character varying, IN p_sender_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_status VARCHAR(20);
    v_stage  SMALLINT;
BEGIN
    SELECT status INTO v_status FROM documents WHERE doc_id = p_doc_id FOR UPDATE;
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Документ % не найден', p_doc_id USING ERRCODE = 'P0002';
    ELSIF v_status IN ('Исполнен', 'В архиве') THEN
        RAISE EXCEPTION 'Документ в статусе «%» нельзя направить по маршруту', v_status
              USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(MAX(stage_no), 0) + 1 INTO v_stage FROM doc_routes WHERE doc_id = p_doc_id;

    INSERT INTO doc_routes (doc_id, stage_no, executor_id, action)
    VALUES (p_doc_id, v_stage, p_executor_id, p_action);

    PERFORM set_config('app.user_id', p_sender_id::TEXT, TRUE);
    UPDATE documents SET status = 'На согласовании'
     WHERE doc_id = p_doc_id AND status <> 'На согласовании';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: counterparties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.counterparties (
    cp_id integer NOT NULL,
    cp_name character varying(150) NOT NULL,
    inn character varying(12) NOT NULL,
    cp_kind character varying(20) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT counterparties_cp_kind_check CHECK (((cp_kind)::text = ANY ((ARRAY['Заказчик'::character varying, 'Поставщик'::character varying, 'Госорган'::character varying, 'Партнёр'::character varying])::text[]))),
    CONSTRAINT counterparties_inn_check CHECK (((inn)::text ~ '^[0-9]{10}([0-9]{2})?$'::text))
);


--
-- Name: TABLE counterparties; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.counterparties IS 'Контрагенты-корреспонденты';


--
-- Name: counterparties_cp_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.counterparties_cp_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: counterparties_cp_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.counterparties_cp_id_seq OWNED BY public.counterparties.cp_id;


--
-- Name: departments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.departments (
    dept_id integer NOT NULL,
    dept_code character varying(10) NOT NULL,
    dept_name character varying(120) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE departments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.departments IS 'Подразделения ООО «ЦИТР»';


--
-- Name: departments_dept_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.departments_dept_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: departments_dept_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.departments_dept_id_seq OWNED BY public.departments.dept_id;


--
-- Name: doc_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.doc_files (
    file_id integer NOT NULL,
    doc_id integer NOT NULL,
    file_name character varying(160) NOT NULL,
    size_kb integer NOT NULL,
    version_no smallint DEFAULT 1 NOT NULL,
    uploaded_by integer NOT NULL,
    uploaded_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT doc_files_size_kb_check CHECK ((size_kb > 0))
);


--
-- Name: TABLE doc_files; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.doc_files IS 'Файлы и версии документов';


--
-- Name: doc_files_file_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.doc_files_file_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: doc_files_file_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.doc_files_file_id_seq OWNED BY public.doc_files.file_id;


--
-- Name: doc_routes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.doc_routes (
    route_id integer NOT NULL,
    doc_id integer NOT NULL,
    stage_no smallint NOT NULL,
    executor_id integer NOT NULL,
    action character varying(20) NOT NULL,
    decision character varying(15) DEFAULT 'Ожидает'::character varying NOT NULL,
    comment character varying(300),
    assigned_at timestamp without time zone DEFAULT now() NOT NULL,
    decided_at timestamp without time zone,
    CONSTRAINT doc_routes_action_check CHECK (((action)::text = ANY ((ARRAY['Согласование'::character varying, 'Подписание'::character varying, 'Исполнение'::character varying, 'Ознакомление'::character varying])::text[]))),
    CONSTRAINT doc_routes_decision_check CHECK (((decision)::text = ANY ((ARRAY['Ожидает'::character varying, 'Согласовано'::character varying, 'Отклонено'::character varying])::text[])))
);


--
-- Name: TABLE doc_routes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.doc_routes IS 'Этапы маршрута согласования';


--
-- Name: doc_routes_route_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.doc_routes_route_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: doc_routes_route_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.doc_routes_route_id_seq OWNED BY public.doc_routes.route_id;


--
-- Name: doc_status_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.doc_status_log (
    log_id bigint NOT NULL,
    doc_id integer NOT NULL,
    old_status character varying(20),
    new_status character varying(20) NOT NULL,
    changed_by integer,
    changed_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE doc_status_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.doc_status_log IS 'Журнал смены статусов';


--
-- Name: doc_status_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.doc_status_log_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: doc_status_log_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.doc_status_log_log_id_seq OWNED BY public.doc_status_log.log_id;


--
-- Name: doc_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.doc_types (
    type_id smallint NOT NULL,
    type_name character varying(80) NOT NULL,
    reg_prefix character varying(5) NOT NULL,
    retention_years smallint NOT NULL,
    CONSTRAINT doc_types_retention_years_check CHECK ((retention_years > 0))
);


--
-- Name: TABLE doc_types; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.doc_types IS 'Виды документов';


--
-- Name: doc_types_type_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.doc_types_type_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: doc_types_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.doc_types_type_id_seq OWNED BY public.doc_types.type_id;


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    doc_id integer NOT NULL,
    reg_number character varying(20) NOT NULL,
    title character varying(200) NOT NULL,
    author_id integer NOT NULL,
    type_id smallint NOT NULL,
    dept_id integer NOT NULL,
    cp_id integer,
    status character varying(20) DEFAULT 'Черновик'::character varying NOT NULL,
    reg_date date DEFAULT CURRENT_DATE NOT NULL,
    due_date date,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_due CHECK (((due_date IS NULL) OR (due_date >= reg_date))),
    CONSTRAINT documents_status_check CHECK (((status)::text = ANY ((ARRAY['Черновик'::character varying, 'На согласовании'::character varying, 'На доработке'::character varying, 'Согласован'::character varying, 'Исполнен'::character varying, 'В архиве'::character varying])::text[])))
);


--
-- Name: TABLE documents; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.documents IS 'Регистрационные карточки документов';


--
-- Name: documents_doc_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documents_doc_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documents_doc_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documents_doc_id_seq OWNED BY public.documents.doc_id;


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    role_id smallint NOT NULL,
    role_code character varying(20) NOT NULL,
    role_name character varying(60) NOT NULL
);


--
-- Name: TABLE roles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.roles IS 'Роли пользователей приложения';


--
-- Name: roles_role_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.roles_role_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: roles_role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.roles_role_id_seq OWNED BY public.roles.role_id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    user_id integer NOT NULL,
    login character varying(40) NOT NULL,
    full_name character varying(120) NOT NULL,
    email character varying(120) NOT NULL,
    "position" character varying(100),
    role_id smallint NOT NULL,
    dept_id integer NOT NULL,
    password_hash character(64) NOT NULL,
    password_salt character(32) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE users; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.users IS 'Пользователи системы';


--
-- Name: users_user_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_user_id_seq OWNED BY public.users.user_id;


--
-- Name: v_dept_doc_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_dept_doc_stats AS
 SELECT dp.dept_name,
    count(d.doc_id) AS docs_total,
    count(d.doc_id) FILTER (WHERE ((d.status)::text = 'На согласовании'::text)) AS on_approval,
    count(d.doc_id) FILTER (WHERE ((d.status)::text = ANY ((ARRAY['Исполнен'::character varying, 'В архиве'::character varying])::text[]))) AS completed,
    count(d.doc_id) FILTER (WHERE ((d.due_date < CURRENT_DATE) AND ((d.status)::text <> ALL ((ARRAY['Исполнен'::character varying, 'В архиве'::character varying])::text[])))) AS overdue,
    round(avg((d.due_date - d.reg_date)), 1) AS avg_term_days
   FROM (public.departments dp
     LEFT JOIN public.documents d ON ((d.dept_id = dp.dept_id)))
  GROUP BY dp.dept_name;


--
-- Name: v_documents_full; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_documents_full AS
 SELECT d.doc_id,
    d.reg_number,
    d.title,
    t.type_name,
    d.status,
    d.reg_date,
    d.due_date,
    u.full_name AS author,
    dp.dept_name AS department,
    COALESCE(c.cp_name, '— внутренний —'::character varying) AS counterparty,
    ((d.due_date < CURRENT_DATE) AND ((d.status)::text <> ALL ((ARRAY['Исполнен'::character varying, 'В архиве'::character varying])::text[]))) AS is_overdue,
    d.updated_at
   FROM ((((public.documents d
     JOIN public.doc_types t ON ((t.type_id = d.type_id)))
     JOIN public.users u ON ((u.user_id = d.author_id)))
     JOIN public.departments dp ON ((dp.dept_id = d.dept_id)))
     LEFT JOIN public.counterparties c ON ((c.cp_id = d.cp_id)));


--
-- Name: v_pending_tasks; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_pending_tasks AS
 SELECT r.route_id,
    r.doc_id,
    d.reg_number,
    d.title,
    r.stage_no,
    r.action,
    r.executor_id,
    u.full_name AS executor,
    r.assigned_at,
    (CURRENT_DATE - (r.assigned_at)::date) AS waiting_days
   FROM ((public.doc_routes r
     JOIN public.documents d ON ((d.doc_id = r.doc_id)))
     JOIN public.users u ON ((u.user_id = r.executor_id)))
  WHERE ((r.decision)::text = 'Ожидает'::text);


--
-- Name: counterparties cp_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.counterparties ALTER COLUMN cp_id SET DEFAULT nextval('public.counterparties_cp_id_seq'::regclass);


--
-- Name: departments dept_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments ALTER COLUMN dept_id SET DEFAULT nextval('public.departments_dept_id_seq'::regclass);


--
-- Name: doc_files file_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_files ALTER COLUMN file_id SET DEFAULT nextval('public.doc_files_file_id_seq'::regclass);


--
-- Name: doc_routes route_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_routes ALTER COLUMN route_id SET DEFAULT nextval('public.doc_routes_route_id_seq'::regclass);


--
-- Name: doc_status_log log_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_status_log ALTER COLUMN log_id SET DEFAULT nextval('public.doc_status_log_log_id_seq'::regclass);


--
-- Name: doc_types type_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_types ALTER COLUMN type_id SET DEFAULT nextval('public.doc_types_type_id_seq'::regclass);


--
-- Name: documents doc_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents ALTER COLUMN doc_id SET DEFAULT nextval('public.documents_doc_id_seq'::regclass);


--
-- Name: roles role_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles ALTER COLUMN role_id SET DEFAULT nextval('public.roles_role_id_seq'::regclass);


--
-- Name: users user_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN user_id SET DEFAULT nextval('public.users_user_id_seq'::regclass);


--
-- Data for Name: counterparties; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.counterparties (cp_id, cp_name, inn, cp_kind, created_at) FROM stdin;
1	ООО «Вектор-Логистик»	7701000101	Заказчик	2026-10-29 10:15:00
2	АО «СеверТехСнаб»	7802000202	Поставщик	2026-10-29 10:20:00
3	ИФНС России № 35 по г. Москве	7735000303	Госорган	2026-10-29 10:25:00
4	ООО «Облачные решения»	7703000404	Партнёр	2026-10-30 11:00:00
5	ООО «МедиаПринт»	5003000505	Поставщик	2026-10-30 11:05:00
\.


--
-- Data for Name: departments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.departments (dept_id, dept_code, dept_name, created_at) FROM stdin;
1	ДИР	Дирекция и канцелярия	2026-10-28 09:00:00
2	ОР	Отдел разработки ПО	2026-10-28 09:00:00
3	ОВ	Отдел внедрения и сопровождения	2026-10-28 09:00:00
4	БУХ	Бухгалтерия	2026-10-28 09:00:00
5	ОК	Отдел кадров	2026-10-28 09:00:00
6	ЮР	Юридическая служба	2026-10-28 09:00:00
\.


--
-- Data for Name: doc_files; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.doc_files (file_id, doc_id, file_name, size_kb, version_no, uploaded_by, uploaded_at) FROM stdin;
1	1	dogovor_vektor_v1.docx	184	1	2	2026-10-29 11:05:00
2	1	dogovor_vektor_v2.docx	191	2	2	2026-10-31 09:12:00
3	2	prikaz_vvod_ekspl.pdf	96	1	2	2026-10-30 09:45:00
4	3	sz_server_zakupka.docx	58	1	5	2026-10-31 14:15:00
5	4	trebovanie_ifns.pdf	322	1	2	2026-11-02 10:07:00
6	6	akt_oktyabr_2026.xlsx	41	1	4	2026-11-06 12:02:00
\.


--
-- Data for Name: doc_routes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.doc_routes (route_id, doc_id, stage_no, executor_id, action, decision, comment, assigned_at, decided_at) FROM stdin;
1	1	1	5	Согласование	Согласовано	Замечаний по сроку SLA нет	2026-10-29 11:10:00	2026-10-30 10:02:00
2	1	2	3	Подписание	Согласовано	\N	2026-10-30 10:05:00	2026-10-31 17:40:00
3	2	1	3	Подписание	Согласовано	\N	2026-10-30 09:50:00	2026-10-30 12:15:00
4	2	2	5	Ознакомление	Согласовано	Ознакомлен	2026-10-30 12:20:00	2026-10-30 14:00:00
5	3	1	4	Согласование	Отклонено	Нет коммерческого предложения от второго поставщика	2026-10-31 14:20:00	2026-11-02 09:30:00
6	4	1	4	Исполнение	Согласовано	Ответ подготовлен, исх. ИС-2026-0001	2026-11-02 10:10:00	2026-11-05 16:35:00
7	5	1	3	Подписание	Ожидает	\N	2026-11-05 16:40:00	\N
8	6	1	5	Согласование	Согласовано	\N	2026-11-06 12:05:00	2026-11-07 11:20:00
9	6	2	3	Подписание	Ожидает	\N	2026-11-07 11:25:00	\N
10	8	1	5	Согласование	Ожидает	\N	2026-11-11 10:30:00	\N
11	9	1	4	Согласование	Согласовано	Бюджет на закупку подтверждён	2026-11-25 14:29:15.946947	2026-11-25 14:29:16.257588
12	9	2	3	Подписание	Согласовано	Подписано	2026-11-25 14:29:15.951953	2026-11-25 14:29:16.263223
\.


--
-- Data for Name: doc_status_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.doc_status_log (log_id, doc_id, old_status, new_status, changed_by, changed_at) FROM stdin;
1	1	Черновик	На согласовании	2	2026-10-29 11:10:00
2	1	На согласовании	Согласован	3	2026-10-31 17:40:00
3	1	Согласован	Исполнен	2	2026-10-31 17:45:00
4	2	Черновик	На согласовании	2	2026-10-30 09:50:00
5	2	На согласовании	Согласован	5	2026-10-30 14:00:00
6	2	Согласован	В архиве	2	2026-11-03 10:00:00
7	3	Черновик	На согласовании	5	2026-10-31 14:20:00
8	3	На согласовании	На доработке	4	2026-11-02 09:30:00
9	4	Черновик	На согласовании	2	2026-11-02 10:10:00
10	4	На согласовании	Исполнен	4	2026-11-05 16:35:00
11	5	Черновик	На согласовании	4	2026-11-05 16:40:00
12	6	Черновик	На согласовании	4	2026-11-06 12:05:00
13	8	Черновик	На согласовании	2	2026-11-11 10:30:00
14	9	\N	Черновик	2	2026-11-25 14:29:15.679512
15	9	Черновик	На согласовании	2	2026-11-25 14:29:15.946947
16	9	На согласовании	Согласован	3	2026-11-25 14:29:16.263223
17	7	Черновик	Исполнен	2	2026-11-25 14:29:16.523661
\.


--
-- Data for Name: doc_types; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.doc_types (type_id, type_name, reg_prefix, retention_years) FROM stdin;
1	Договор	ДГ	5
2	Приказ	ПР	75
3	Служебная записка	СЗ	5
4	Входящее письмо	ВХ	5
5	Исходящее письмо	ИС	5
6	Акт выполненных работ	АК	5
7	Протокол совещания	ПК	10
8	Доверенность	ДВ	3
\.


--
-- Data for Name: documents; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.documents (doc_id, reg_number, title, author_id, type_id, dept_id, cp_id, status, reg_date, due_date, created_at, updated_at) FROM stdin;
1	ДГ-2026-0001	Договор на сопровождение ИС «Склад» с ООО «Вектор-Логистик»	2	1	1	1	Исполнен	2026-10-29	2026-11-12	2026-10-29 11:02:00	2026-10-31 17:45:00
2	ПР-2026-0001	Приказ о вводе в эксплуатацию системы ЦИТР.Документ	2	2	1	\N	В архиве	2026-10-30	2026-11-06	2026-10-30 09:40:00	2026-11-03 10:00:00
3	СЗ-2026-0001	Служебная записка о закупке серверного оборудования	5	3	2	2	На доработке	2026-10-31	2026-11-10	2026-10-31 14:12:00	2026-11-02 09:30:00
4	ВХ-2026-0001	Требование ИФНС о представлении пояснений	2	4	4	3	Исполнен	2026-11-02	2026-11-09	2026-11-02 10:05:00	2026-11-05 16:35:00
5	ИС-2026-0001	Ответ на требование ИФНС № 35	4	5	4	3	На согласовании	2026-11-05	2026-11-09	2026-11-05 16:30:00	2026-11-05 16:40:00
6	АК-2026-0001	Акт выполненных работ за октябрь 2026 г.	4	6	4	1	На согласовании	2026-11-06	2026-11-20	2026-11-06 12:00:00	2026-11-07 11:25:00
8	ДГ-2026-0002	Договор аренды облачных мощностей с ООО «Облачные решения»	2	1	3	4	На согласовании	2026-11-11	2026-11-25	2026-11-11 10:20:00	2026-11-11 10:30:00
9	ДГ-2026-0003	Договор поставки серверного оборудования	2	1	1	2	Согласован	2026-11-25	2026-12-08	2026-11-25 14:29:15.679512	2026-11-25 14:29:16.263223
7	ПК-2026-0001	Протокол совещания по переходу на ЭДО	6	7	5	\N	Исполнен	2026-11-09	\N	2026-11-09 15:45:00	2026-11-25 14:29:16.523661
\.


--
-- Data for Name: roles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.roles (role_id, role_code, role_name) FROM stdin;
1	ADMIN	Администратор системы
2	CLERK	Делопроизводитель
3	MANAGER	Руководитель (согласующий)
4	VIEWER	Наблюдатель
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.users (user_id, login, full_name, email, "position", role_id, dept_id, password_hash, password_salt, is_active, created_at, updated_at) FROM stdin;
1	admin	Ковалёв Артём Сергеевич	a.kovalev@citr.local	Системный администратор	1	2	6abdf44422a67bb8075ba5b760da11d36f489824a547eef08ec8ecc4590bcded	614db1c638bb36ce08cf4afc4463767d	t	2026-11-25 14:29:13.413665	2026-11-25 14:29:13.413665
2	orlova	Орлова Марина Викторовна	m.orlova@citr.local	Делопроизводитель	2	1	00e25a015df3a3b52c6e43c794b1a86ea90036e4c8da6671515c6b947aee44ba	8a7f0d88dad07e5951ec515b4d7cf3fa	t	2026-11-25 14:29:13.413665	2026-11-25 14:29:13.413665
3	belov	Белов Игорь Андреевич	i.belov@citr.local	Генеральный директор	3	1	6a62c293879ccb9d7f2b76fd477a79677720871009cd5f2b5343893c9a271aeb	11e625af4ea2959f82748eb4a5cc7440	t	2026-11-25 14:29:13.413665	2026-11-25 14:29:13.413665
4	sidorenko	Сидоренко Ольга Павловна	o.sidorenko@citr.local	Главный бухгалтер	3	4	cf9b312139eb321ffb6313a88e10b179c967b9a7847627d7f7a2b5fb5f0d3fc1	40688fcfeb00897ccfb8b15a33a5a0dd	t	2026-11-25 14:29:13.413665	2026-11-25 14:29:13.413665
5	frolov	Фролов Денис Олегович	d.frolov@citr.local	Руководитель отдела разработки	3	2	196ed6f7dc969dd4daf81f7a9bd12e1f3a854a0a83f9bb6f000b8509168f10cd	9b521c2cd98e7d45e9d9fe977f11f5dd	t	2026-11-25 14:29:13.413665	2026-11-25 14:29:13.413665
6	gromova	Громова Анна Игоревна	a.gromova@citr.local	Специалист по кадрам	2	5	d1a62ba960d890a2fa48d6ac48fda600f56e7d1dab02df73a993102ff63eba14	fab79c96f852fb4cc645baa45108348c	t	2026-11-25 14:29:13.413665	2026-11-25 14:29:13.413665
7	nikitin	Никитин Павел Романович	p.nikitin@citr.local	Аналитик	4	3	0d7fca2330290e21bda18e53c2f567ce90e34b76312e1e90b1a390c11ce5b5bc	b9fc641a00d67ce0ac0f72346e794a30	t	2026-11-25 14:29:13.413665	2026-11-25 14:29:13.413665
\.


--
-- Name: counterparties_cp_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.counterparties_cp_id_seq', 5, true);


--
-- Name: departments_dept_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.departments_dept_id_seq', 6, true);


--
-- Name: doc_files_file_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.doc_files_file_id_seq', 6, true);


--
-- Name: doc_routes_route_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.doc_routes_route_id_seq', 12, true);


--
-- Name: doc_status_log_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.doc_status_log_log_id_seq', 18, true);


--
-- Name: doc_types_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.doc_types_type_id_seq', 8, true);


--
-- Name: documents_doc_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.documents_doc_id_seq', 10, true);


--
-- Name: roles_role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.roles_role_id_seq', 4, true);


--
-- Name: users_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.users_user_id_seq', 7, true);


--
-- Name: counterparties counterparties_inn_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.counterparties
    ADD CONSTRAINT counterparties_inn_key UNIQUE (inn);


--
-- Name: counterparties counterparties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.counterparties
    ADD CONSTRAINT counterparties_pkey PRIMARY KEY (cp_id);


--
-- Name: departments departments_dept_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_dept_code_key UNIQUE (dept_code);


--
-- Name: departments departments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_pkey PRIMARY KEY (dept_id);


--
-- Name: doc_files doc_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_files
    ADD CONSTRAINT doc_files_pkey PRIMARY KEY (file_id);


--
-- Name: doc_routes doc_routes_doc_id_stage_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_routes
    ADD CONSTRAINT doc_routes_doc_id_stage_no_key UNIQUE (doc_id, stage_no);


--
-- Name: doc_routes doc_routes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_routes
    ADD CONSTRAINT doc_routes_pkey PRIMARY KEY (route_id);


--
-- Name: doc_status_log doc_status_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_status_log
    ADD CONSTRAINT doc_status_log_pkey PRIMARY KEY (log_id);


--
-- Name: doc_types doc_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_types
    ADD CONSTRAINT doc_types_pkey PRIMARY KEY (type_id);


--
-- Name: doc_types doc_types_reg_prefix_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_types
    ADD CONSTRAINT doc_types_reg_prefix_key UNIQUE (reg_prefix);


--
-- Name: doc_types doc_types_type_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_types
    ADD CONSTRAINT doc_types_type_name_key UNIQUE (type_name);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (doc_id);


--
-- Name: documents documents_reg_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_reg_number_key UNIQUE (reg_number);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (role_id);


--
-- Name: roles roles_role_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_role_code_key UNIQUE (role_code);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_login_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_login_key UNIQUE (login);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- Name: ix_documents_dept; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_documents_dept ON public.documents USING btree (dept_id);


--
-- Name: ix_documents_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_documents_status ON public.documents USING btree (status);


--
-- Name: ix_routes_executor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_routes_executor ON public.doc_routes USING btree (executor_id, decision);


--
-- Name: ix_status_log_doc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_status_log_doc ON public.doc_status_log USING btree (doc_id, changed_at);


--
-- Name: doc_files trg_doc_files_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_doc_files_version BEFORE INSERT ON public.doc_files FOR EACH ROW EXECUTE FUNCTION public.fn_doc_files_version();


--
-- Name: documents trg_documents_status_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_documents_status_audit AFTER INSERT OR UPDATE OF status ON public.documents FOR EACH ROW EXECUTE FUNCTION public.fn_documents_status_audit();


--
-- Name: documents trg_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_documents_updated_at BEFORE UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: users trg_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: doc_files doc_files_doc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_files
    ADD CONSTRAINT doc_files_doc_id_fkey FOREIGN KEY (doc_id) REFERENCES public.documents(doc_id) ON DELETE CASCADE;


--
-- Name: doc_files doc_files_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_files
    ADD CONSTRAINT doc_files_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES public.users(user_id);


--
-- Name: doc_routes doc_routes_doc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_routes
    ADD CONSTRAINT doc_routes_doc_id_fkey FOREIGN KEY (doc_id) REFERENCES public.documents(doc_id) ON DELETE CASCADE;


--
-- Name: doc_routes doc_routes_executor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_routes
    ADD CONSTRAINT doc_routes_executor_id_fkey FOREIGN KEY (executor_id) REFERENCES public.users(user_id);


--
-- Name: doc_status_log doc_status_log_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_status_log
    ADD CONSTRAINT doc_status_log_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.users(user_id);


--
-- Name: doc_status_log doc_status_log_doc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_status_log
    ADD CONSTRAINT doc_status_log_doc_id_fkey FOREIGN KEY (doc_id) REFERENCES public.documents(doc_id) ON DELETE CASCADE;


--
-- Name: documents documents_author_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_author_id_fkey FOREIGN KEY (author_id) REFERENCES public.users(user_id);


--
-- Name: documents documents_cp_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_cp_id_fkey FOREIGN KEY (cp_id) REFERENCES public.counterparties(cp_id) ON DELETE SET NULL;


--
-- Name: documents documents_dept_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_dept_id_fkey FOREIGN KEY (dept_id) REFERENCES public.departments(dept_id);


--
-- Name: documents documents_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_type_id_fkey FOREIGN KEY (type_id) REFERENCES public.doc_types(type_id);


--
-- Name: users users_dept_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_dept_id_fkey FOREIGN KEY (dept_id) REFERENCES public.departments(dept_id);


--
-- Name: users users_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO citr_reader;


--
-- Name: PROCEDURE sp_decide_route(IN p_route_id integer, IN p_decision character varying, IN p_comment character varying, IN p_user_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_decide_route(IN p_route_id integer, IN p_decision character varying, IN p_comment character varying, IN p_user_id integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_decide_route(IN p_route_id integer, IN p_decision character varying, IN p_comment character varying, IN p_user_id integer) TO citr_clerk;
GRANT ALL ON PROCEDURE public.sp_decide_route(IN p_route_id integer, IN p_decision character varying, IN p_comment character varying, IN p_user_id integer) TO citr_admin;


--
-- Name: PROCEDURE sp_register_document(IN p_title character varying, IN p_type_id smallint, IN p_author_id integer, IN p_cp_id integer, IN p_due_date date, INOUT p_doc_id integer, INOUT p_reg_number character varying); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_register_document(IN p_title character varying, IN p_type_id smallint, IN p_author_id integer, IN p_cp_id integer, IN p_due_date date, INOUT p_doc_id integer, INOUT p_reg_number character varying) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_register_document(IN p_title character varying, IN p_type_id smallint, IN p_author_id integer, IN p_cp_id integer, IN p_due_date date, INOUT p_doc_id integer, INOUT p_reg_number character varying) TO citr_clerk;
GRANT ALL ON PROCEDURE public.sp_register_document(IN p_title character varying, IN p_type_id smallint, IN p_author_id integer, IN p_cp_id integer, IN p_due_date date, INOUT p_doc_id integer, INOUT p_reg_number character varying) TO citr_admin;


--
-- Name: PROCEDURE sp_register_user(IN p_login character varying, IN p_full_name character varying, IN p_email character varying, IN p_position character varying, IN p_dept_id integer, IN p_role_code character varying, IN p_hash character, IN p_salt character, INOUT p_user_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_register_user(IN p_login character varying, IN p_full_name character varying, IN p_email character varying, IN p_position character varying, IN p_dept_id integer, IN p_role_code character varying, IN p_hash character, IN p_salt character, INOUT p_user_id integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_register_user(IN p_login character varying, IN p_full_name character varying, IN p_email character varying, IN p_position character varying, IN p_dept_id integer, IN p_role_code character varying, IN p_hash character, IN p_salt character, INOUT p_user_id integer) TO citr_admin;


--
-- Name: PROCEDURE sp_send_for_approval(IN p_doc_id integer, IN p_executor_id integer, IN p_action character varying, IN p_sender_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_send_for_approval(IN p_doc_id integer, IN p_executor_id integer, IN p_action character varying, IN p_sender_id integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_send_for_approval(IN p_doc_id integer, IN p_executor_id integer, IN p_action character varying, IN p_sender_id integer) TO citr_clerk;
GRANT ALL ON PROCEDURE public.sp_send_for_approval(IN p_doc_id integer, IN p_executor_id integer, IN p_action character varying, IN p_sender_id integer) TO citr_admin;


--
-- Name: TABLE counterparties; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.counterparties TO citr_reader;
GRANT INSERT,UPDATE ON TABLE public.counterparties TO citr_clerk;
GRANT ALL ON TABLE public.counterparties TO citr_admin;


--
-- Name: SEQUENCE counterparties_cp_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.counterparties_cp_id_seq TO citr_clerk;
GRANT ALL ON SEQUENCE public.counterparties_cp_id_seq TO citr_admin;


--
-- Name: TABLE departments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.departments TO citr_reader;
GRANT ALL ON TABLE public.departments TO citr_admin;


--
-- Name: SEQUENCE departments_dept_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.departments_dept_id_seq TO citr_admin;


--
-- Name: TABLE doc_files; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.doc_files TO citr_reader;
GRANT INSERT,DELETE,UPDATE ON TABLE public.doc_files TO citr_clerk;
GRANT ALL ON TABLE public.doc_files TO citr_admin;


--
-- Name: SEQUENCE doc_files_file_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.doc_files_file_id_seq TO citr_clerk;
GRANT ALL ON SEQUENCE public.doc_files_file_id_seq TO citr_admin;


--
-- Name: TABLE doc_routes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.doc_routes TO citr_reader;
GRANT INSERT,DELETE,UPDATE ON TABLE public.doc_routes TO citr_clerk;
GRANT ALL ON TABLE public.doc_routes TO citr_admin;


--
-- Name: SEQUENCE doc_routes_route_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.doc_routes_route_id_seq TO citr_clerk;
GRANT ALL ON SEQUENCE public.doc_routes_route_id_seq TO citr_admin;


--
-- Name: TABLE doc_status_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.doc_status_log TO citr_reader;
GRANT ALL ON TABLE public.doc_status_log TO citr_admin;


--
-- Name: SEQUENCE doc_status_log_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.doc_status_log_log_id_seq TO citr_admin;


--
-- Name: TABLE doc_types; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.doc_types TO citr_reader;
GRANT ALL ON TABLE public.doc_types TO citr_admin;


--
-- Name: SEQUENCE doc_types_type_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.doc_types_type_id_seq TO citr_admin;


--
-- Name: TABLE documents; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.documents TO citr_reader;
GRANT INSERT,DELETE,UPDATE ON TABLE public.documents TO citr_clerk;
GRANT ALL ON TABLE public.documents TO citr_admin;


--
-- Name: SEQUENCE documents_doc_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.documents_doc_id_seq TO citr_clerk;
GRANT ALL ON SEQUENCE public.documents_doc_id_seq TO citr_admin;


--
-- Name: TABLE roles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.roles TO citr_reader;
GRANT ALL ON TABLE public.roles TO citr_admin;


--
-- Name: SEQUENCE roles_role_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.roles_role_id_seq TO citr_admin;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.users TO citr_reader;
GRANT ALL ON TABLE public.users TO citr_admin;


--
-- Name: SEQUENCE users_user_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.users_user_id_seq TO citr_admin;


--
-- Name: TABLE v_dept_doc_stats; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_dept_doc_stats TO citr_reader;
GRANT ALL ON TABLE public.v_dept_doc_stats TO citr_admin;


--
-- Name: TABLE v_documents_full; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_documents_full TO citr_reader;
GRANT ALL ON TABLE public.v_documents_full TO citr_admin;


--
-- Name: TABLE v_pending_tasks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_pending_tasks TO citr_reader;
GRANT ALL ON TABLE public.v_pending_tasks TO citr_admin;


--
-- PostgreSQL database dump complete
--

\unrestrict QCznDrwEPQG3EPd3gixozYoAOEXO3PuviAQdF2eURkJkrghuByYAODOBplhv7Qz

